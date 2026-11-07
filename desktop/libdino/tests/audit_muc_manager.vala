using Xmpp;
using Dino.Entities;

namespace Dino.Test {

class MucManagerAudit : Gee.TestCase {
    private const string NS_DISCO_INFO = "http://jabber.org/protocol/disco#info";
    private const string NS_MUC = "http://jabber.org/protocol/muc";
    private const string NS_MUC_ADMIN = "http://jabber.org/protocol/muc#admin";
    private const string NS_MUC_OWNER = "http://jabber.org/protocol/muc#owner";
    private const string NS_MUC_USER = "http://jabber.org/protocol/muc#user";
    private const string NS_MUC_HATS = "urn:xmpp:hats:0";
    private const string NS_VCARD = "vcard-temp";
    private const string AUDIT_AVATAR_HASH =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    public MucManagerAudit() {
        base("MucManagerAudit");
        add_test("custom_history_period_persists_offline_and_rejects_stale_scope", test_custom_history_period_scope);
        add_test("v55_history_period_migration_preserves_coverage", test_v55_history_period_migration);
        add_test("Auto_first_join_preserves_default_history_window", () => test_custom_history_window(0, 0));
        add_test("custom_one_day_first_join_fetches_full_window", () => test_custom_history_window(1, 0));
        add_test("custom365_first_join_bypasses_soft30_day_limit", () => test_custom_history_window(365, 0));
        add_test("custom365_history_honours_actual_panic_setter", () => test_custom_history_window(365, 1));
        add_test("Auto_preserves_old_panic_marker_window", () => test_custom_history_window(0, 1));
        add_test("custom365_history_honours_clear_floor", () => test_custom_history_window(365, 2));
        add_test("custom365_history_honours_expiry_floor", () => test_custom_history_window(365, 3));
        add_test("explicit_history_refresh_replaces_only_own_serial_owner", test_custom_history_refresh);
        add_test("manual_MUC_reload_restores_locally_cleared_history_after_rejoin",
            () => test_manual_history_restore(false));
        add_test("manual_MUC_reload_respects_a_new_clear_during_fetch",
            () => test_manual_history_restore(true));
        add_test("account_archive_bounded_complete_allows_broader_backfill", test_account_archive_bounded_backfill);
        add_test("direct_refresh_pages_known_messages_without_global_coverage", () => test_direct_history_refresh(0));
        add_test("direct_refresh_empty_complete_is_success", () => test_direct_history_refresh(1));
        add_test("direct_refresh_deleted_target_blocks_before_pipeline", () => test_direct_history_refresh(2));
        add_test("direct_refresh_swapped_stream_blocks_before_pipeline", () => test_direct_history_refresh(3));
        add_test("direct_refresh_deleted_target_after_snapshot_wait_blocks_decrypt", () => test_direct_history_refresh(4));
        add_test("direct_refresh_rejects_foreign_peer_from_archive", () => test_direct_history_refresh(5));
        add_test("direct_refresh_rejects_before_hard_panic_floor", () => test_direct_history_refresh(6));
        add_test("direct_refresh_replacement_preserves_other_contact", () => test_direct_history_refresh(7));
        add_test("direct_refresh_clamps_panic_clear_and_expiry_floor", () => test_direct_history_refresh(8));
        add_test("direct_refresh_unsupported_is_unavailable", () => test_direct_history_refresh(9));
        add_test("direct_refresh_deleted_target_after_earlier_listener_blocks_decrypt", () => test_direct_history_refresh(10));
        add_test("direct_refresh_staleCHAT_room_target_cannot_enter_PM_resolver", () => test_direct_history_refresh(11));
        add_test("direct_refresh_errorIQ_complete_fin_never_decrypts_or_succeeds", () => test_direct_history_refresh(12));
        add_test("direct_refresh_restores_locally_cleared_history", () => test_direct_history_refresh(13));
        add_test("direct_refresh_respects_new_clear_during_fetch", () => test_direct_history_refresh(14));
        add_test("direct_refresh_respects_new_clear_during_discovery", () => test_direct_history_refresh(15));
        add_test("direct_refresh_restores_canonical_history_from_dialog_clone", () => test_direct_history_refresh(16));
        add_test("direct_refresh_pages_past_control_only_page", () => test_direct_history_refresh(17));
        add_test("reload_summary_direct_keeps_new_omemo", () => test_reload_summary(false, 0));
        add_test("reload_summary_direct_keeps_xep0027", () => test_reload_summary(false, 1));
        add_test("reload_summary_direct_keeps_xep0374", () => test_reload_summary(false, 2));
        add_test("reload_summary_direct_keeps_plaintext", () => test_reload_summary(false, 3));
        add_test("reload_summary_MUC_keeps_new_omemo", () => test_reload_summary(true, 0));
        add_test("reload_summary_MUC_keeps_xep0027", () => test_reload_summary(true, 1));
        add_test("reload_summary_MUC_keeps_xep0374", () => test_reload_summary(true, 2));
        add_test("reload_summary_MUC_keeps_plaintext", () => test_reload_summary(true, 3));
        add_test("reload_summary_private_MUC_keeps_new_omemo", () => test_reload_summary(true, 0, 1));
        add_test("reload_summary_private_MUC_only_unrecoverable_omemo_finishes", () => test_reload_summary(true, 0, 2));
        add_test("reload_summary_private_MUC_ignores_same_address_CHAT", () => test_reload_summary(true, 0, 3));
        add_test("manual_private_MUC_reload_without_archive_finishes", () => test_muc_reload_unavailable(0));
        add_test("manual_private_MUC_reload_late_no_archive_finishes", () => test_muc_reload_unavailable(1));
        add_test("manual_private_MUC_reload_completion_preserves_replacement", () => test_muc_reload_unavailable(2));

        add_test("bounded_latest_completion_keeps_existing_archive_start_open",
            () => test_complete_mam_range(true, true));
        add_test("bounded_first_latest_completion_keeps_archive_start_open",
            () => test_complete_mam_range(false, true));
        add_test("unfiltered_complete_latest_marks_archive_exhausted",
            () => test_complete_mam_range(false, false));
        add_test("bounded_backfill_can_expand_earlier_again",
            test_bounded_backfill);
        add_test("same_stream_rejoin_live_cursor_excludes_offline_gap",
            () => test_rejoin_live_gap(false));
        add_test("same_stream_rejoin_MAM_respects_panic_floor",
            () => test_rejoin_live_gap(true));
        add_test("v54_MAM_coverage_migration_preserves_history_and_refetches",
            test_v54_mam_coverage_migration);
        add_test("cleared_MAM_ciphertext_is_rejected_before_DECRYPT",
            () => test_mam_privacy_before_decrypt(false, false));
        add_test("expired_MAM_ciphertext_is_rejected_before_DECRYPT",
            () => test_mam_privacy_before_decrypt(true, false));
        add_test("cleared_MAM_without_time_is_rejected_before_DECRYPT",
            () => test_mam_privacy_before_decrypt(false, true));
        add_test("expired_MAM_without_time_is_rejected_before_DECRYPT",
            () => test_mam_privacy_before_decrypt(true, true));
        add_test("fresh_MAM_and_live_ciphertext_keep_room_and_account_policy_scope",
            test_mam_privacy_scope_and_live);
        add_test("MAM_clear_during_held_listener_stops_before_DECRYPT",
            () => test_mam_policy_change_while_held(false));
        add_test("MAM_expiry_during_held_listener_stops_before_DECRYPT",
            () => test_mam_policy_change_while_held(true));
        add_test("MAM_cancelled_before_start_preserves_existing_live_cursors",
            test_mam_cancelled_before_start);
        add_test("snapshot_barrier_drains_receive_listener_through_store", () => test_snapshot_pipeline_barrier(false));
        add_test("snapshot_live_cursor_excludes_message_waiting_during_drain", () => test_snapshot_pipeline_barrier(true));
        add_test("active_muc_survives_bookmark_autojoin_false", test_active_muc_survives_bookmark_autojoin_false);
        add_test("active_muc_survives_bookmark_removal", test_active_muc_survives_bookmark_removal);
        add_test("provisional_disconnect_preserves_resumable_MUC_runtime",
            test_provisional_disconnect_preserves_resumable_muc_runtime);
        add_test("provisional_disconnect_requeues_failed_autojoin",
            test_provisional_disconnect_requeues_failed_autojoin);
        add_test("provisional_disconnect_defers_manual_join_bookmark",
            test_provisional_disconnect_defers_manual_join_bookmark);
        add_test("stale_MAM_completion_preserves_reconnect_sync_owner",
            test_stale_mam_completion_preserves_reconnect_sync_owner);
        add_test("provisional_disconnect_cancels_and_restarts_MAM_once",
            test_provisional_disconnect_cancels_and_restarts_mam_once);
        add_test("fresh_MUC_joins_serialize_MAM_catchup",
            test_fresh_muc_joins_serialize_mam_catchup);
        add_test("MAM_disco_error_preserves_retry_intent",
            test_mam_disco_error_preserves_retry_intent);
        add_test("first_join_MAM_stays_latest_only_after_requeue",
            test_first_join_mam_stays_latest_only_after_requeue);
        add_test("cancelled_MAM_with_existing_range_releases_queue",
            test_cancelled_mam_with_existing_range_releases_queue);
        add_test("MAM_IQ_error_retries_exactly_once",
            test_mam_iq_error_retries_exactly_once);
        add_test("late_MAM_disco_success_wakes_queue",
            test_late_mam_disco_success_wakes_queue);
        add_test("exhausted_multi_room_MAM_retries_do_not_spin",
            test_exhausted_multi_room_mam_retries_do_not_spin);
        add_test("MAM_retry_state_cleans_up_after_part_and_left",
            test_mam_retry_state_cleans_up_after_part_and_left);
        add_test("stale_account_MAM_completion_preserves_new_owner",
            test_stale_account_mam_completion_preserves_new_owner);
        add_test("parallel_account_and_MUC_MAM_timestamps_are_query_scoped",
            test_parallel_account_and_muc_mam_timestamps_are_query_scoped);
        add_test("MAM_readiness_gate_blocks_query_and_range_commit",
            test_mam_readiness_gate_blocks_query_and_range_commit);
        add_test("MAM_readiness_loss_during_page_preserves_cursor",
            test_mam_readiness_loss_during_page_preserves_cursor);
        add_test("force_rejoin_bypasses_local_join_cache", test_force_rejoin_bypasses_local_join_cache);
        add_test("manual_rejoin_after_leave_bypasses_stale_own_nick", test_manual_rejoin_after_leave_bypasses_stale_own_nick);
        add_test("permanent_leave_closes_before_bookmark_remove_completes",
            test_permanent_leave_closes_before_bookmark_remove_completes);
        add_test("permanent_leave_failure_keeps_local_state_and_intent",
            test_permanent_leave_failure_keeps_local_state_and_intent);
        add_test("permanent_leave_rejoin_supersedes_stale_remove",
            test_permanent_leave_rejoin_supersedes_stale_remove);
        add_test("permanent_remove_echo_before_rejoin_is_consumed",
            test_permanent_remove_echo_before_rejoin_is_consumed);
        add_test("displaced_destroy_remove_waiter_completes",
            test_displaced_destroy_remove_waiter_completes);
        add_test("repeated_permanent_leave_is_locally_idempotent",
            test_repeated_permanent_leave_is_locally_idempotent);
        add_test("stale_provider_snapshot_keeps_pending_remove",
            test_stale_provider_snapshot_keeps_pending_remove);
        add_test("provider_swap_requeues_current_remove_intent",
            test_provider_swap_requeues_current_remove_intent);
        add_test("null_snapshot_retries_restored_pending_remove",
            test_null_snapshot_retries_restored_pending_remove);
        add_test("initial_bookmark_snapshot_emits_update",
            test_initial_bookmark_snapshot_emits_update);
        add_test("room_avatar_reconnect_expires_previous_stream_TTL",
            test_room_avatar_reconnect_expires_previous_stream_ttl);
        add_test("room_avatar_queue_refills_bookmarks_above_cap",
            test_room_avatar_queue_refills_bookmarks_above_cap);
        add_test("room_avatar_disconnect_cancels_active_IQ",
            test_room_avatar_disconnect_cancels_active_iq);
        add_test("add_bookmark_provider_swap_requeues_current_intent",
            test_add_bookmark_provider_swap_requeues_current_intent);
        add_test("part_recreates_bookmark_removed_by_stale_generation",
            test_part_recreates_bookmark_removed_by_stale_generation);
        add_test("manual_bookmark_remove_notifies_exactly_once",
            test_manual_bookmark_remove_notifies_exactly_once);
        add_test("manual_remove_add_race_preserves_new_bookmark",
            test_manual_remove_add_race_preserves_new_bookmark);
        add_test("worker_start_rejection_preserves_room_lifecycle", test_worker_start_rejection_preserves_room_lifecycle);
        add_test("repeated_account_removal_is_safe", test_repeated_account_removal_is_safe);
        add_test("room_observers_route_only_matching_account_and_room", test_room_observer_routing);
        add_test("visible_muc_prioritizes_autojoin_queue", test_visible_muc_prioritizes_autojoin_queue);
        add_test("initial_roster_commits_at_self_presence", test_initial_roster_commit);
        add_test("initial_join_accepts_advertised_occupant_ids", test_initial_join_accepts_advertised_occupant_ids);
        add_test("private_muc_conversations_keep_occupant_identity", test_private_muc_conversation_identity);
        add_test("private_muc_reply_reuses_exact_full_jid_conversation", test_private_muc_reply_reuses_exact_full_jid_conversation);
        add_test("private_muc_identity_upgrade_preserves_thread", test_private_muc_identity_upgrade_preserves_thread);
        add_test("private_muc_control_routing_never_binds_identity",
            test_private_muc_control_routing_never_binds_identity);
        add_test("private_muc_room_info_owns_conversation_encryption",
            test_private_muc_room_info_owns_conversation_encryption);
        add_test("room_pm_identity_purge_is_room_scoped", test_room_pm_identity_purge_is_room_scoped);
        add_test("stale_occupant_identity_signals_without_lifecycle_are_ignored", test_stale_occupant_identity_signals_without_lifecycle_are_ignored);
        add_test("private_muc_join_hydrates_and_rehydrates_affiliation_snapshot",
            test_private_muc_join_hydrates_and_rehydrates_affiliation_snapshot);
        add_test("private_muc_early_readiness_keeps_enter_room_info_owner",
            test_private_muc_early_readiness_keeps_enter_room_info_owner);
        add_test("private_muc_incoming_encryption_waits_for_enter_room_info",
            test_private_muc_incoming_encryption_waits_for_enter_room_info);
        add_test("private_muc_displayed_markers_track_verified_readers",
            test_private_muc_displayed_markers_track_verified_readers);
        add_test("private_muc_room_info_failure_settles_pending_readiness",
            test_private_muc_room_info_failure_settles_pending_readiness);
        add_test("private_muc_join_affiliation_failure_stays_incomplete",
            test_private_muc_join_affiliation_failure_stays_incomplete);
        add_test("private_muc_mixed_unsent_waits_for_snapshot_recovery",
            test_private_muc_mixed_unsent_waits_for_snapshot_recovery);
        add_test("private_muc_send_requires_joined_live_full_occupant", test_private_muc_send_requires_joined_live_full_occupant);
        add_test("v44_migration_preserves_private_muc_identity", test_v44_migration_preserves_private_muc_identity);
        add_test("unchanged_members_only_does_not_preflight_affiliations", test_unchanged_members_only_does_not_preflight_affiliations);
        add_test("room_config_verification_mismatch_is_local_sync_warning", test_room_config_verification_mismatch_is_local_sync_warning);
        add_test("room_config_verification_get_error_is_local_sync_warning", test_room_config_verification_get_error_is_local_sync_warning);
        add_test("members_only_query_failure_sends_no_mutation", test_members_only_query_failure_sends_no_mutation);
        add_test("members_only_unknown_original_runs_safe_preflight", test_members_only_unknown_original_sends_no_mutation);
        add_test("members_only_unresolved_occupant_fails_before_mutation", test_members_only_unresolved_occupant_fails_before_mutation);
        add_test("members_only_config_failure_preserves_ambiguous_preflight", test_members_only_config_failure_rolls_back_preflight);
        add_test("members_only_demotion_during_preflight_stops_mutation", test_members_only_demotion_during_preflight_stops_mutation);
        add_test("members_only_stream_change_during_preflight_stops_mutation", test_members_only_stream_change_during_preflight_stops_mutation);
        add_test("config_same_stream_rejoin_generation_is_stale", test_config_same_stream_rejoin_generation_is_stale);
        add_test("get_config_same_stream_rejoin_generation_is_stale", test_get_config_same_stream_rejoin_generation_is_stale);
        add_test("sequential_members_only_saves_use_updated_baseline", test_sequential_members_only_saves_use_updated_baseline);
        add_test("members_only_semi_anonymous_sends_no_private_notice", test_members_only_semi_anonymous_sends_no_private_notice);
        add_test("members_only_rollback_failure_is_not_clean_success", test_members_only_rollback_failure_is_not_clean_success);
        add_test("members_only_rollback_preserves_concurrent_promotion", test_members_only_rollback_preserves_concurrent_promotion);
        add_test("config_bookmark_failure_is_not_clean_success", test_config_bookmark_failure_is_not_clean_success);
        add_test("config_disco_failure_still_syncs_verified_bookmark",
            test_config_disco_failure_still_syncs_verified_bookmark);
        add_test("contact_removal_success_scoped_and_persistent", () => test_contact_history_removal(0));
        add_test("contact_removal_rejected_keeps_history", () => test_contact_history_removal(1));
        add_test("contact_removal_late_reply_keeps_replacement_chat", () => test_contact_history_removal(2));
        add_test("contact_removal_late_reply_keeps_new_stream", () => test_contact_history_removal(3));
        add_test("contact_removal_offline_keeps_history", () => test_contact_history_removal(4));
        add_test("contact_removal_roster_only_keeps_history", () => test_contact_history_removal(5));
        add_test("removed_contact_live_message_reopens_chat", () => test_removed_contact_message(0));
        add_test("removed_contact_new_MAM_message_reopens_chat", () => test_removed_contact_message(1));
        add_test("removed_contact_cleared_MAM_stays_deleted", () => test_removed_contact_message(2));
        add_test("removed_contact_undated_MAM_stays_deleted", () => test_removed_contact_message(3));
        add_test("removed_contact_sent_message_reopens_chat", () => test_removed_contact_message(4));
        add_test("admin_destroy_success_without_occupancy", () => test_admin_room_destruction(0));
        add_test("admin_destroy_error_note_keeps_room", () => test_admin_room_destruction(1));
        add_test("admin_destroy_executing_keeps_room", () => test_admin_room_destruction(2));
        add_test("admin_destroy_canceled_keeps_room", () => test_admin_room_destruction(3));
        add_test("admin_destroy_wrong_session_keeps_room", () => test_admin_room_destruction(4));
        add_test("admin_destroy_late_reply_keeps_new_stream", () => test_admin_room_destruction(5));
        add_test("admin_destroy_late_reply_keeps_rejoined_room", () => test_admin_room_destruction(6));
        add_test("admin_destroy_invalid_room_keeps_room", () => test_admin_room_destruction(7));
        add_test("admin_destroy_normalizes_room_address", () => test_admin_room_destruction(8));
        add_test("owner_destroy_presence_before_IQ_is_idempotent", test_owner_destroy_presence_before_iq);
        add_test("destroy_rejection_preserves_local_room_state", test_destroy_rejection_preserves_local_room_state);
        add_test("server_destroy_presence_without_110_retires_room", () => test_server_destroy_presence(false));
        add_test("server_destroy_presence_with_110_retires_room", () => test_server_destroy_presence(true));
        add_test("destroy_stream_change_preserves_new_local_state", test_destroy_stream_change_preserves_new_local_state);
        add_test("destroy_bookmark_failure_is_not_clean_success", test_destroy_bookmark_failure_is_not_clean_success);
        add_test("legacy_snapshot_before_remove_confirms_destroy",
            test_legacy_snapshot_before_remove_confirms_destroy);
        add_test("destroy_provider_swap_waits_for_requeued_remove",
            test_destroy_provider_swap_waits_for_requeued_remove);
        add_test("timed_ban_restores_known_none_and_clears_persistence", test_timed_ban_restores_known_none_and_clears_persistence);
        add_test("timed_ban_unknown_after_reconnect_retries_without_iq", test_timed_ban_unknown_after_reconnect_retries_without_iq);
        add_test("timed_ban_reason_parser_is_exact", test_timed_ban_reason_parser_is_exact);
        add_test("muc_affiliation_permission_matrix_matches_xep0045", test_muc_affiliation_permission_matrix_matches_xep0045);
        add_test("checked_muc_mutations_fail_closed", test_checked_muc_mutations_fail_closed);
        add_test("muc_avatar_missing_vcard_allows_checked_owner_publish",
            test_muc_avatar_missing_vcard_allows_checked_owner_publish);
        add_test("historical_message_identity_rejects_reused_nick", test_historical_message_identity_rejects_reused_nick);
        add_test("stale_admin_room_context_is_fenced", test_stale_admin_room_context_is_fenced);
        add_test("loaded_config_and_destroy_confirmation_are_generation_fenced", test_loaded_config_and_destroy_confirmation_are_generation_fenced);
        add_test("context_config_resyncs_only_occupant_projection_changes",
            test_context_config_resyncs_only_occupant_projection_changes);
        add_test("confirmed_hats_and_presencebroadcast_update_live_worker",
            test_confirmed_hats_and_presencebroadcast_update_live_worker);
        add_test("verified_whois_readback_fallback_is_privacy_authoritative",
            test_verified_whois_readback_fallback_is_privacy_authoritative);
        add_test("successful_whois_disco_replay_is_not_duplicated",
            test_successful_whois_disco_replay_is_not_duplicated);
        add_test("confirmed_role_change_waits_for_presence_without_replay",
            test_confirmed_role_change_waits_for_presence_without_replay);
        add_test("confirmed_affiliation_change_waits_for_presence_without_replay",
            test_confirmed_affiliation_change_waits_for_presence_without_replay);
        add_test("mediated_invite_requires_join_and_forwards_current_stream",
            test_mediated_invite_requires_join_and_forwards_current_stream);
        add_test("mediated_invite_permission_matrix",
            test_mediated_invite_permission_matrix);
        add_test("allowinvites_config_roundtrip_updates_gate",
            test_allowinvites_config_roundtrip_updates_gate);
    }

    private void test_active_muc_survives_bookmark_autojoin_false() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            Conference conference = new Conference() {
                jid = conversation.counterpart,
                nick = conversation.nickname,
                autojoin = false
            };

            muc_manager.handle_conference_added_for_tests(account, conference);

            fail_if_not(conversation.active, "bookmark autojoin=false must not close an active MUC conversation");
        });
    }

    private void test_provisional_disconnect_preserves_resumable_muc_runtime() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.disco_non_anonymous = true;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_provisional_disconnect_muc_runtime_audit.begin(
                stream_interactor, muc_manager, account, conversation, stream,
                (obj, res) => {
                    try {
                        run_provisional_disconnect_muc_runtime_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out waiting for provisional-disconnect MUC audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        }, true);
    }

    private async void run_provisional_disconnect_muc_runtime_audit(
            StreamInteractor stream_interactor, MucManager muc_manager,
            Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        bool room_info_ready = false;
        var room_info_promise = new Gee.Promise<bool>();
        ulong room_info_handler = muc_manager.room_info_updated.connect(
            (delivered_account, room) => {
                if (room_info_ready || !delivered_account.equals(account) ||
                        !room.equals_bare(conversation.counterpart)) return;
                room_info_ready = true;
                room_info_promise.set_value(true);
            });
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(joined, "provisional-disconnect MUC join");
        if (!room_info_ready) {
            try {
                yield room_info_promise.future.wait_async();
            } catch (Gee.FutureError e) {
                SignalHandler.disconnect(muc_manager, room_info_handler);
                throw new IOError.FAILED(
                    "room privacy discovery failed: %s".printf(e.message));
            }
        }
        SignalHandler.disconnect(muc_manager, room_info_handler);
        if (muc_manager.get_room_real_jid_visibility(account,
                conversation.counterpart) !=
                Xmpp.Xep.Muc.RealJidVisibility.ANYONE) {
            throw new IOError.FAILED(
                "the reconnect audit must establish non-anonymous room authority");
        }

        MucRoomKey? before = muc_manager.get_room_occupant_generation(account,
            conversation.counterpart);
        if (before == null ||
                !muc_manager.has_joined_runtime_for_tests(account,
                    conversation.counterpart)) {
            throw new IOError.FAILED(
                "the audit setup must establish joined MUC and worker state");
        }

        // NetworkMonitor moves the real connection state offline even though
        // the same stream may later recover through one ping.
        stream_interactor.connection_manager
            .set_provisional_disconnected_for_tests(account);
        yield wait_muc_audit_tick();
        if (stream_interactor.get_stream(account) != null ||
                stream_interactor.connection_manager
                    .get_provisionally_retained_stream(account) != stream) {
            throw new IOError.FAILED(
                "the reconnect audit must exercise worker fanout without a volatile current stream");
        }

        MucRoomKey? after = muc_manager.get_room_occupant_generation(account,
            conversation.counterpart);
        if (after == null || !((!) after).matches((!) before) ||
                !muc_manager.has_joined_runtime_for_tests(account,
                    conversation.counterpart)) {
            throw new IOError.FAILED(
                "a provisional disconnect must preserve resumable joined and worker state");
        }
        if (muc_manager.get_room_occupants_snapshot(account,
                conversation.counterpart) == null) {
            throw new IOError.FAILED(
                "worker output queued before disconnect must still commit while offline");
        }

        Jid offline_occupant = conversation.counterpart.with_resource(
            "offline-bob");
        MucRoomDelta? offline_delta = null;
        bool offline_role_received = false;
        Xmpp.Xep.Muc.Role? offline_role = null;
        var offline_delta_promise = new Gee.Promise<MucRoomDelta>();
        ulong offline_delta_handler =
            muc_manager.room_occupants_changed_batch.connect(
                (delivered_account, room, delta) => {
                    if (offline_delta != null ||
                            !delivered_account.equals(account) ||
                            !room.equals_bare(conversation.counterpart)) {
                        return;
                    }
                    for (uint i = 0; i < delta.changed_count; i++) {
                        if (delta.changed_at(i).occupant_full_jid ==
                                offline_occupant.to_string()) {
                            offline_delta = delta;
                            offline_delta_promise.set_value(delta);
                            return;
                        }
                    }
                });
        ulong offline_role_handler =
            muc_manager.received_occupant_role.connect(
                (delivered_account, occupant, role) => {
                    if (!delivered_account.equals(account) ||
                            !occupant.equals(offline_occupant)) return;
                    offline_role_received = true;
                    offline_role = role;
                });
        stream.emit_presence(build_occupant_presence(
            conversation.counterpart, "offline-bob", account.full_jid,
            "member", "participant", new Jid("bob@example.test"),
            AUDIT_AVATAR_HASH));
        if (offline_delta == null) {
            try {
                offline_delta = yield offline_delta_promise.future.wait_async();
            } catch (Gee.FutureError e) {
                SignalHandler.disconnect(muc_manager,
                    offline_delta_handler);
                SignalHandler.disconnect(muc_manager,
                    offline_role_handler);
                throw new IOError.FAILED(
                    "offline occupant worker update failed: %s".printf(
                        e.message));
            }
        }
        yield wait_muc_audit_tick();
        SignalHandler.disconnect(muc_manager, offline_delta_handler);
        SignalHandler.disconnect(muc_manager, offline_role_handler);
        if (!offline_role_received ||
                offline_role != Xmpp.Xep.Muc.Role.PARTICIPANT) {
            throw new IOError.FAILED(
                "offline worker compatibility fanout must retain the immutable participant role");
        }
        MucRoomDelta? offline_snapshot =
            muc_manager.get_room_occupants_snapshot(account,
                conversation.counterpart);
        MucOccupantSnapshot? offline_occupant_snapshot = null;
        if (offline_snapshot != null) {
            for (uint i = 0; i < ((!) offline_snapshot).changed_count; i++) {
                if (((!) offline_snapshot).changed_at(i).occupant_full_jid ==
                        offline_occupant.to_string()) {
                    offline_occupant_snapshot =
                        ((!) offline_snapshot).changed_at(i);
                    break;
                }
            }
        }
        if (offline_occupant_snapshot == null) {
            throw new IOError.FAILED(
                "presence from the retained stream must not be dropped while recovery-ping is pending");
        }
        if (((!) offline_occupant_snapshot).real_bare_jid !=
                    "bob@example.test" ||
                ((!) offline_occupant_snapshot).avatar_hash !=
                    AUDIT_AVATAR_HASH) {
            throw new IOError.FAILED(
                "retained-stream worker state must preserve authorized JID and avatar metadata");
        }

        Xmpp.Xep.Muc.Module muc_module = stream.get_module<
            Xmpp.Xep.Muc.Module>(Xmpp.Xep.Muc.Module.IDENTITY);
        muc_module.room_real_jid_visibility_revoked(stream,
            conversation.counterpart);
        MucRoomDelta? scrubbed_snapshot =
            muc_manager.get_room_occupants_snapshot(account,
                conversation.counterpart);
        if (scrubbed_snapshot == null) {
            throw new IOError.FAILED(
                "privacy revocation must retain a scrubbed display snapshot");
        }
        for (uint i = 0; i < ((!) scrubbed_snapshot).changed_count; i++) {
            MucOccupantSnapshot candidate =
                ((!) scrubbed_snapshot).changed_at(i);
            if (candidate.occupant_full_jid == offline_occupant.to_string() &&
                    candidate.real_bare_jid != null) {
                throw new IOError.FAILED(
                    "offline privacy revocation must scrub worker real JIDs immediately");
            }
        }

        AvatarManager? avatar_manager = stream_interactor.get_module<
            AvatarManager>(AvatarManager.IDENTITY);
        if (avatar_manager == null ||
                ((!) avatar_manager).get_avatar_source_hash_for_tests(
                    account, offline_occupant, AvatarSource.VCARD) !=
                        AUDIT_AVATAR_HASH) {
            throw new IOError.FAILED(
                "the retained presence must establish the occupant avatar hash");
        }

        // A cache miss can finish while the transport is paused. Preserve only
        // that exact network intent; do not replay every occupant in the room.
        ((!) avatar_manager).queue_muc_avatar_network_fetch_for_tests(account,
            offline_occupant, AUDIT_AVATAR_HASH);
        ((!) avatar_manager).queue_muc_avatar_network_fetch_for_tests(account,
            offline_occupant, AUDIT_AVATAR_HASH);
        if (((!) avatar_manager)
                .get_paused_muc_avatar_fetch_count_for_tests(account) != 1 ||
                ((!) avatar_manager)
                .get_queued_muc_avatar_fetch_count_for_tests(account) != 0) {
            throw new IOError.FAILED(
                "a paused MUC avatar fetch must be retained exactly once without starting network work");
        }
        stream_interactor.connection_manager.set_connection_state_for_tests(
            account, ConnectionManager.ConnectionState.CONNECTED);
        if (((!) avatar_manager)
                .get_paused_muc_avatar_fetch_count_for_tests(account) != 0 ||
                ((!) avatar_manager)
                .get_queued_muc_avatar_fetch_count_for_tests(account) != 1) {
            throw new IOError.FAILED(
                "same-stream recovery must requeue only the interrupted MUC avatar fetch");
        }
        if (((!) avatar_manager).get_avatar_source_hash_for_tests(account,
                offline_occupant, AvatarSource.VCARD) != AUDIT_AVATAR_HASH) {
            throw new IOError.FAILED(
                "same-stream recovery must retain the established occupant avatar hash");
        }

        // Model a dead transport followed by a replacement whose modules are
        // attached but whose XEP-0198 outcome is not known yet.  A second
        // NetworkMonitor offline event must preserve the replacement decision;
        // it must never reclassify this new stream as the retained old one.
        stream_interactor.connection_manager
            .set_stream_replacement_pending_for_tests(account);
        var replacement_stream = new MucManagerAuditStream(
            new Jid("example.test"), conversation.counterpart,
            conversation.nickname);
        attach_muc_stream_modules_for_tests(stream_interactor, account,
            replacement_stream);
        stream_interactor.connection_manager.set_connected_stream_for_tests(
            account, replacement_stream);
        if (!stream_interactor.connection_manager
                .is_stream_replacement_pending(account) ||
                !((!) avatar_manager)
                    .is_muc_avatar_account_paused_for_tests(account)) {
            throw new IOError.FAILED(
                "an attached replacement stream must stay paused until fresh-vs-resumed is resolved");
        }
        stream_interactor.connection_manager
            .set_provisional_disconnected_for_tests(account);
        if (!stream_interactor.connection_manager
                    .is_stream_replacement_pending(account) ||
                stream_interactor.connection_manager
                    .get_provisionally_retained_stream(account) != null ||
                !muc_manager.has_joined_runtime_for_tests(account,
                    conversation.counterpart)) {
            throw new IOError.FAILED(
                "offline during replacement negotiation must not replay or discard the suspended MUC session");
        }

        // This terminal transition also models a replacement attempt ending in
        // an unrecoverable TLS/authentication decision.
        stream_interactor.connection_manager.set_connection_state_for_tests(
            account, ConnectionManager.ConnectionState.DISCONNECTED);
        yield wait_muc_audit_tick();
        if (muc_manager.has_joined_runtime_for_tests(account,
                conversation.counterpart)) {
            throw new IOError.FAILED(
                "a terminal disconnect must clear MUC runtime instead of accepting late room work");
        }
        if (((!) avatar_manager).get_avatar_source_hash_for_tests(account,
                offline_occupant, AvatarSource.VCARD) != null) {
            throw new IOError.FAILED(
                "a terminal disconnect must clear stale occupant avatar identity");
        }
    }

    private void test_provisional_disconnect_requeues_failed_autojoin() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.defer_join_presence = true;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_failed_autojoin_requeue_audit.begin(stream_interactor,
                muc_manager, account, conversation, stream, (obj, res) => {
                    try {
                        run_failed_autojoin_requeue_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out waiting for failed autojoin requeue";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_failed_autojoin_requeue_audit(
            StreamInteractor stream_interactor, MucManager muc_manager,
            Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        var conference = new Conference() {
            jid = conversation.counterpart,
            nick = conversation.nickname,
            autojoin = true
        };
        muc_manager.queue_autojoin_candidate_for_tests(account, conference,
            true);

        bool processing_completed = false;
        muc_manager.process_next_autojoin_for_tests.begin(account,
            (obj, res) => {
                muc_manager.process_next_autojoin_for_tests.end(res);
                processing_completed = true;
            });
        while (stream.join_presence_count == 0) yield wait_muc_audit_tick();

        stream_interactor.connection_manager
            .set_provisional_disconnected_for_tests(account);
        stream.get_module<Xmpp.Xep.Muc.Module>(
            Xmpp.Xep.Muc.Module.IDENTITY).cancel_enter(stream,
                conversation.counterpart, false);
        while (!processing_completed) yield wait_muc_audit_tick();

        Jid? queued = muc_manager.peek_autojoin_candidate_for_tests(account);
        if (queued == null || !((!) queued).equals_bare(
                conversation.counterpart)) {
            throw new IOError.FAILED(
                "an autojoin interrupted by a provisional transport pause must be retried");
        }
        muc_manager.clear_autojoin_queue_for_tests(account);
        stream_interactor.connection_manager.set_connection_state_for_tests(
            account, ConnectionManager.ConnectionState.CONNECTED);
    }

    private void test_provisional_disconnect_defers_manual_join_bookmark() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var provider = new MucManagerAuditBookmarksProvider();
            muc_manager.set_bookmarks_provider_for_tests(account, provider);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.defer_join_presence = true;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_deferred_manual_join_bookmark_audit.begin(stream_interactor,
                muc_manager, account, conversation, stream, provider,
                (obj, res) => {
                    try {
                        run_deferred_manual_join_bookmark_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out waiting for deferred manual-join bookmark";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_deferred_manual_join_bookmark_audit(
            StreamInteractor stream_interactor, MucManager muc_manager,
            Account account, Conversation conversation,
            MucManagerAuditStream stream,
            MucManagerAuditBookmarksProvider provider) throws Error {
        bool join_completed = false;
        Xmpp.Xep.Muc.JoinResult? joined = null;
        muc_manager.join.begin(account, conversation.counterpart,
            conversation.nickname, null, false, null, false, false,
            (obj, res) => {
                joined = muc_manager.join.end(res);
                join_completed = true;
            });
        while (stream.join_presence_count == 0) yield wait_muc_audit_tick();

        stream_interactor.connection_manager
            .set_provisional_disconnected_for_tests(account);
        stream.emit_presence(build_bare_room_presence(
            conversation.counterpart, account.full_jid));
        stream.emit_presence(build_self_presence(conversation.counterpart,
            conversation.nickname, account.full_jid));
        while (!join_completed) yield wait_muc_audit_tick();
        validate_join_result(joined,
            "manual join completed during provisional disconnect");
        if (provider.get_count != 0 || provider.add_count != 0 ||
                provider.replace_count != 0) {
            throw new IOError.FAILED(
                "bookmark I/O must remain deferred while the retained transport is paused");
        }
        if (!muc_manager.has_pending_muc_mam_sync_for_tests(account,
                conversation.counterpart)) {
            throw new IOError.FAILED(
                "MUC MAM catch-up must remain deferred while no sendable stream exists");
        }

        stream_interactor.connection_manager.set_connection_state_for_tests(
            account, ConnectionManager.ConnectionState.CONNECTED);
        while (provider.add_count == 0 && provider.replace_count == 0) {
            yield wait_muc_audit_tick();
        }
        bool found = false;
        foreach (Conference conference in provider.conferences) {
            if (conference.jid != null && ((!) conference.jid).equals_bare(
                    conversation.counterpart) && conference.autojoin) {
                found = true;
                break;
            }
        }
        if (!found || provider.get_count != 1 || provider.add_count != 1) {
            throw new IOError.FAILED(
                "same-stream recovery must flush the deferred manual-join bookmark exactly once");
        }
        if (muc_manager.has_pending_muc_mam_sync_for_tests(account,
                conversation.counterpart)) {
            throw new IOError.FAILED(
                "same-stream recovery must consume the deferred MUC MAM intent");
        }
    }

    private void test_stale_mam_completion_preserves_reconnect_sync_owner() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            Cancellable cancelled_sync = new Cancellable();
            Cancellable reconnect_sync = new Cancellable();

            muc_manager.set_muc_mam_sync_owner_for_tests(account,
                conversation.counterpart, cancelled_sync);
            muc_manager.set_muc_mam_sync_owner_for_tests(account,
                conversation.counterpart, reconnect_sync);
            muc_manager.finish_muc_mam_sync(account,
                conversation.counterpart, cancelled_sync);
            if (!muc_manager.is_muc_mam_sync_owner_for_tests(account,
                    conversation.counterpart, reconnect_sync)) {
                throw new IOError.FAILED(
                    "a stale cancelled MAM callback must not untrack the reconnect sync");
            }

            muc_manager.finish_muc_mam_sync(account,
                conversation.counterpart, reconnect_sync);
            if (muc_manager.is_muc_mam_sync_owner_for_tests(account,
                    conversation.counterpart, reconnect_sync)) {
                throw new IOError.FAILED(
                    "the current MAM callback must release its own sync owner");
            }
        });
    }

    private void test_provisional_disconnect_cancels_and_restarts_mam_once() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.disco_mam = true;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_mam_reconnect_audit.begin(stream_interactor, muc_manager,
                account, conversation, stream, (obj, res) => {
                    try {
                        run_mam_reconnect_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out waiting for MUC MAM reconnect audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_mam_reconnect_audit(
            StreamInteractor stream_interactor, MucManager muc_manager,
            Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(joined, "MAM reconnect audit join");

        int ticks = 0;
        while (stream.mam_iq_count < 1 && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.mam_iq_count != 1) {
            throw new IOError.FAILED(
                "the joined room must start exactly one held MAM query");
        }

        stream_interactor.connection_manager
            .set_provisional_disconnected_for_tests(account);
        if (!muc_manager.has_pending_muc_mam_sync_for_tests(account,
                conversation.counterpart)) {
            throw new IOError.FAILED(
                "disconnect must preserve the interrupted MAM intent");
        }

        Xmpp.MessageArchiveManagement.Flag mam_flag =
            Xmpp.MessageArchiveManagement.Flag.get_flag(stream);
        ticks = 0;
        while (!mam_flag.active_query_ids.is_empty && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (!mam_flag.active_query_ids.is_empty) {
            throw new IOError.FAILED(
                "disconnect cancellation must close the old MAM query promptly");
        }

        // A result from the cancelled request must find no waiter and must not
        // reopen its archived-message acceptance window.
        stream.emit_mam_success(0);
        yield wait_muc_audit_low_tick();
        if (!mam_flag.active_query_ids.is_empty) {
            throw new IOError.FAILED(
                "a late cancelled MAM result must remain fenced");
        }

        stream_interactor.connection_manager.set_connection_state_for_tests(
            account, ConnectionManager.ConnectionState.CONNECTED);
        ticks = 0;
        while (stream.mam_iq_count < 2 && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.mam_iq_count != 2 ||
                muc_manager.has_pending_muc_mam_sync_for_tests(account,
                    conversation.counterpart)) {
            throw new IOError.FAILED(
                "same-stream recovery must restart the MAM intent exactly once");
        }
        for (int i = 0; i < 10; i++) yield wait_muc_audit_low_tick();
        if (stream.mam_iq_count != 2) {
            throw new IOError.FAILED(
                "reconnect must not fan out duplicate MAM requests");
        }

        // Cancel the held replacement query so test teardown has no live
        // archive waiter.
        stream_interactor.connection_manager
            .set_provisional_disconnected_for_tests(account);
        ticks = 0;
        while (!mam_flag.active_query_ids.is_empty && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
    }

    private void test_fresh_muc_joins_serialize_mam_catchup() {
        with_active_muc((stream_interactor, account, first_conversation) => {
            ConversationManager conversation_manager = (!)
                stream_interactor.get_module<ConversationManager>(
                    ConversationManager.IDENTITY);
            Conversation second_conversation =
                conversation_manager.create_conversation(
                    new Jid("second@conference.example.test"), account,
                    Conversation.Type.GROUPCHAT);
            second_conversation.nickname = first_conversation.nickname;
            conversation_manager.start_conversation(second_conversation);

            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                first_conversation.counterpart,
                first_conversation.nickname);
            stream.add_joinable_room_for_tests(second_conversation.counterpart,
                second_conversation.nickname);
            stream.disco_mam = true;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_fresh_mam_serialization_audit.begin(stream_interactor,
                muc_manager, account, first_conversation,
                second_conversation, stream, (obj, res) => {
                    try {
                        run_fresh_mam_serialization_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out waiting for fresh MUC MAM serialization";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_fresh_mam_serialization_audit(
            StreamInteractor stream_interactor, MucManager muc_manager,
            Account account, Conversation first_conversation,
            Conversation second_conversation, MucManagerAuditStream stream)
            throws Error {
        Xmpp.Xep.Muc.JoinResult? first_join = yield muc_manager.join(account,
            first_conversation.counterpart, first_conversation.nickname,
            null, true);
        validate_join_result(first_join, "first serialized MAM join");
        int ticks = 0;
        while (stream.mam_iq_count < 1 && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.mam_iq_count != 1) {
            throw new IOError.FAILED(
                "the first fresh room must start one held MAM query");
        }

        Xmpp.Xep.Muc.JoinResult? second_join = yield muc_manager.join(account,
            second_conversation.counterpart, second_conversation.nickname,
            null, true);
        validate_join_result(second_join, "second serialized MAM join");
        for (int i = 0; i < 10; i++) yield wait_muc_audit_low_tick();
        if (stream.mam_iq_count != 1 ||
                !muc_manager.has_pending_muc_mam_sync_for_tests(account,
                    second_conversation.counterpart)) {
            throw new IOError.FAILED(
                "a second fresh room must wait behind the first MAM query");
        }

        stream.emit_mam_success(0);
        ticks = 0;
        while (stream.mam_iq_count < 2 && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.mam_iq_count != 2 ||
                muc_manager.has_pending_muc_mam_sync_for_tests(account,
                    second_conversation.counterpart)) {
            throw new IOError.FAILED(
                "the second room must start only after the first MAM FIN");
        }

        stream_interactor.connection_manager
            .set_provisional_disconnected_for_tests(account);
        Xmpp.MessageArchiveManagement.Flag mam_flag =
            Xmpp.MessageArchiveManagement.Flag.get_flag(stream);
        ticks = 0;
        while (!mam_flag.active_query_ids.is_empty && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
    }

    private void test_mam_disco_error_preserves_retry_intent() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.disco_error_condition =
                Xmpp.ErrorStanza.CONDITION_SERVICE_UNAVAILABLE;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_mam_disco_error_audit.begin(muc_manager, account,
                conversation, (obj, res) => {
                    try {
                        run_mam_disco_error_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out waiting for failed MAM disco audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_mam_disco_error_audit(MucManager muc_manager,
            Account account, Conversation conversation) throws Error {
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(joined, "failed MAM disco audit join");
        int ticks = 0;
        while (!muc_manager.has_pending_muc_mam_sync_for_tests(account,
                conversation.counterpart) && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (!muc_manager.has_pending_muc_mam_sync_for_tests(account,
                conversation.counterpart)) {
            throw new IOError.FAILED(
                "a failed disco IQ must preserve the MAM retry intent");
        }
    }

    private void test_first_join_mam_stays_latest_only_after_requeue() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            Jid first_join_room = new Jid(
                "first-join@conference.example.test");
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                first_join_room, conversation.nickname);
            stream.disco_mam = true;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            attach_account_module_for_tests<
                Xmpp.MessageArchiveManagement.Module>(stream_interactor,
                    account, stream,
                    Xmpp.MessageArchiveManagement.Module.IDENTITY);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_first_join_mam_mode_audit.begin(stream_interactor, muc_manager,
                account, first_join_room, conversation.nickname, stream,
                (obj, res) => {
                    try {
                        run_first_join_mam_mode_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(8, () => {
                timeout_id = 0;
                failure = "timed out waiting for first-join MAM mode audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_first_join_mam_mode_audit(
            StreamInteractor stream_interactor, MucManager muc_manager,
            Account account, Jid room, string nick,
            MucManagerAuditStream stream) throws Error {
        ConversationManager conversation_manager = (!)
            stream_interactor.get_module<ConversationManager>(
                ConversationManager.IDENTITY);
        if (conversation_manager.get_conversation(room, account) != null) {
            throw new IOError.FAILED(
                "the first-join audit room must not have a Conversation before join");
        }

        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            room, nick, null, true);
        validate_join_result(joined, "unknown-room MAM join");

        int ticks = 0;
        while (stream.mam_iq_count < 1 && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.mam_iq_count != 1) {
            throw new IOError.FAILED(
                "an unknown first join must start exactly one latest-page MAM IQ");
        }

        stream_interactor.connection_manager
            .set_provisional_disconnected_for_tests(account);
        Xmpp.MessageArchiveManagement.Flag mam_flag =
            Xmpp.MessageArchiveManagement.Flag.get_flag(stream);
        ticks = 0;
        while (!mam_flag.active_query_ids.is_empty && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (!mam_flag.active_query_ids.is_empty ||
                !muc_manager.has_pending_muc_mam_sync_for_tests(account,
                    room)) {
            throw new IOError.FAILED(
                "disconnect must cancel and retain the unknown-room MAM intent");
        }

        stream_interactor.connection_manager.set_connection_state_for_tests(
            account, ConnectionManager.ConnectionState.CONNECTED);
        ticks = 0;
        while (stream.mam_iq_count < 2 && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.mam_iq_count != 2) {
            throw new IOError.FAILED(
                "reconnect must restart the retained first-join MAM intent once");
        }

        // A non-complete page with a real archived message creates a DB range.
        // FULL mode would then issue a second backwards query; LATEST_ONLY must
        // stop after this one page, including after the disconnect requeue.
        stream.emit_mam_page(1, false);
        ticks = 0;
        while ((!mam_flag.active_query_ids.is_empty ||
                muc_manager.has_pending_muc_mam_sync_for_tests(account, room)) &&
                ticks++ < 200) {
            yield wait_muc_audit_low_tick();
        }
        for (int i = 0; i < 20; i++) yield wait_muc_audit_low_tick();
        if (stream.mam_iq_count != 2) {
            throw new IOError.FAILED(
                "a first-join LATEST_ONLY retry must not start a backwards MAM IQ");
        }
        if (get_mam_range_count_for_tests(account, room) != 1) {
            throw new IOError.FAILED(
                "the first-join audit page must be processed into one MAM DB range");
        }
    }

    private void test_cancelled_mam_with_existing_range_releases_queue() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            seed_mam_range_for_tests(account, conversation.counterpart, false);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.disco_mam = true;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            attach_account_module_for_tests<
                Xmpp.MessageArchiveManagement.Module>(stream_interactor,
                    account, stream,
                    Xmpp.MessageArchiveManagement.Module.IDENTITY);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            stream_interactor.connection_manager.stream_attached_modules(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_existing_range_cancel_audit.begin(stream_interactor,
                muc_manager, account, conversation, stream, (obj, res) => {
                    try {
                        run_existing_range_cancel_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(8, () => {
                timeout_id = 0;
                failure = "timed out waiting for existing-range cancellation audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_existing_range_cancel_audit(
            StreamInteractor stream_interactor, MucManager muc_manager,
            Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(joined, "existing-range MAM join");

        int ticks = 0;
        while (stream.mam_iq_count < 1 && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.mam_iq_count != 1) {
            throw new IOError.FAILED(
                "the existing-range audit must start one latest-page IQ");
        }

        stream_interactor.connection_manager
            .set_provisional_disconnected_for_tests(account);
        Xmpp.MessageArchiveManagement.Flag mam_flag =
            Xmpp.MessageArchiveManagement.Flag.get_flag(stream);
        ticks = 0;
        while (!mam_flag.active_query_ids.is_empty && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        for (int i = 0; i < 20; i++) yield wait_muc_audit_low_tick();
        if (!mam_flag.active_query_ids.is_empty ||
                stream.mam_iq_count != 1 ||
                stream.mam_iq_attempt_count != 1 ||
                !muc_manager.has_pending_muc_mam_sync_for_tests(account,
                    conversation.counterpart)) {
            throw new IOError.FAILED(
                "cancel with a DB range must not issue an offline follow-up IQ or lose its intent");
        }

        // A resumed second IQ proves the cancelled coroutine released the
        // account-serial queue instead of hanging on a null stream callback.
        stream_interactor.connection_manager.set_connection_state_for_tests(
            account, ConnectionManager.ConnectionState.CONNECTED);
        ticks = 0;
        while (stream.mam_iq_count < 2 && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.mam_iq_count != 2) {
            throw new IOError.FAILED(
                "the MAM queue remained stuck after cancelling with an existing DB range");
        }
        for (int i = 0; i < 20; i++) yield wait_muc_audit_low_tick();
        if (stream.mam_iq_count != 2 || stream.mam_iq_attempt_count != 2) {
            throw new IOError.FAILED(
                "reconnect must restart exactly one existing-range MAM IQ");
        }

        stream_interactor.connection_manager
            .set_provisional_disconnected_for_tests(account);
        ticks = 0;
        while (!mam_flag.active_query_ids.is_empty && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
    }

    private void test_mam_iq_error_retries_exactly_once() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.disco_mam = true;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            attach_account_module_for_tests<
                Xmpp.MessageArchiveManagement.Module>(stream_interactor,
                    account, stream,
                    Xmpp.MessageArchiveManagement.Module.IDENTITY);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_mam_iq_error_retry_audit.begin(muc_manager, account,
                conversation, stream, (obj, res) => {
                    try {
                        run_mam_iq_error_retry_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(8, () => {
                timeout_id = 0;
                failure = "timed out waiting for MAM IQ retry audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_mam_iq_error_retry_audit(MucManager muc_manager,
            Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(joined, "MAM IQ error retry join");
        int ticks = 0;
        while (stream.mam_iq_count < 1 && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.mam_iq_count != 1) {
            throw new IOError.FAILED(
                "the MAM IQ retry audit must start one initial query");
        }

        stream.emit_mam_error(0,
            Xmpp.ErrorStanza.CONDITION_SERVICE_UNAVAILABLE);
        ticks = 0;
        while (!muc_manager.has_pending_muc_mam_sync_for_tests(account,
                conversation.counterpart) && stream.mam_iq_count < 2 &&
                ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (!muc_manager.has_pending_muc_mam_sync_for_tests(account,
                conversation.counterpart)) {
            throw new IOError.FAILED(
                "a MAM IQ error must retain its retry intent before retrying");
        }

        bool retry_deadline = false;
        uint retry_timeout_id = 0;
        retry_timeout_id = Timeout.add_seconds(4, () => {
            retry_timeout_id = 0;
            retry_deadline = true;
            return Source.REMOVE;
        });
        while (stream.mam_iq_count < 2 && !retry_deadline) {
            yield wait_muc_audit_low_tick();
        }
        if (retry_timeout_id != 0) Source.remove(retry_timeout_id);
        if (stream.mam_iq_count != 2) {
            throw new IOError.FAILED(
                "a retained MAM IQ error intent did not retry");
        }

        stream.emit_mam_success(1);
        Xmpp.MessageArchiveManagement.Flag mam_flag =
            Xmpp.MessageArchiveManagement.Flag.get_flag(stream);
        ticks = 0;
        while ((!mam_flag.active_query_ids.is_empty ||
                muc_manager.has_pending_muc_mam_sync_for_tests(account,
                    conversation.counterpart)) && ticks++ < 200) {
            yield wait_muc_audit_low_tick();
        }
        yield wait_muc_audit_delay(1500);
        if (stream.mam_iq_count != 2 ||
                !mam_flag.active_query_ids.is_empty ||
                muc_manager.has_pending_muc_mam_sync_for_tests(account,
                    conversation.counterpart)) {
            throw new IOError.FAILED(
                "a successful MAM retry must settle once without a third query");
        }
    }

    private void test_late_mam_disco_success_wakes_queue() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.disco_mam = true;
            stream.defer_disco_info = true;
            stream.fail_first_disco_info = true;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            attach_account_module_for_tests<
                Xmpp.MessageArchiveManagement.Module>(stream_interactor,
                    account, stream,
                    Xmpp.MessageArchiveManagement.Module.IDENTITY);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_late_mam_disco_success_audit.begin(muc_manager, account,
                conversation, stream, (obj, res) => {
                    try {
                        run_late_mam_disco_success_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(20, () => {
                timeout_id = 0;
                failure = "timed out waiting for late MAM disco success audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_late_mam_disco_success_audit(
            MucManager muc_manager, Account account,
            Conversation conversation, MucManagerAuditStream stream)
            throws Error {
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(joined, "late MAM disco success join");

        bool feature_timeout_deadline = false;
        uint feature_timeout_id = 0;
        feature_timeout_id = Timeout.add_seconds(13, () => {
            feature_timeout_id = 0;
            feature_timeout_deadline = true;
            return Source.REMOVE;
        });
        while (!muc_manager.has_muc_mam_retry_scheduled_for_tests(account,
                conversation.counterpart) && !feature_timeout_deadline) {
            yield wait_muc_audit_low_tick();
        }
        if (feature_timeout_id != 0) Source.remove(feature_timeout_id);
        if (!muc_manager.has_pending_muc_mam_sync_for_tests(account,
                conversation.counterpart) ||
                !muc_manager.has_muc_mam_retry_scheduled_for_tests(account,
                    conversation.counterpart) || stream.disco_iq_count != 2 ||
                stream.held_disco_count != 1) {
            throw new IOError.FAILED(
                "the held MAM feature lookup did not reach its timeout intent");
        }

        // Release the already timed-out successful response.  The specific
        // late callback must wake the queue before the generic one-second retry
        // timer; otherwise this 750 ms fence fails.
        stream.emit_next_held_disco_success();
        bool immediate_deadline = false;
        uint immediate_timeout_id = 0;
        immediate_timeout_id = Timeout.add(750, () => {
            immediate_timeout_id = 0;
            immediate_deadline = true;
            return Source.REMOVE;
        });
        while (stream.mam_iq_count < 1 && !immediate_deadline) {
            yield wait_muc_audit_low_tick();
        }
        if (immediate_timeout_id != 0) Source.remove(immediate_timeout_id);
        if (stream.mam_iq_count != 1) {
            throw new IOError.FAILED(
                "late successful MAM disco did not wake the pending queue immediately");
        }

        stream.emit_mam_success(0);
        Xmpp.MessageArchiveManagement.Flag mam_flag =
            Xmpp.MessageArchiveManagement.Flag.get_flag(stream);
        int ticks = 0;
        while ((!mam_flag.active_query_ids.is_empty ||
                muc_manager.has_pending_muc_mam_sync_for_tests(account,
                    conversation.counterpart)) && ticks++ < 200) {
            yield wait_muc_audit_low_tick();
        }
        stream.release_held_disco_successes();
        yield wait_muc_audit_delay(1500);
        if (stream.mam_iq_count != 1 ||
                !mam_flag.active_query_ids.is_empty ||
                muc_manager.has_pending_muc_mam_sync_for_tests(account,
                    conversation.counterpart)) {
            throw new IOError.FAILED(
                "late disco wake must cancel its timer and settle exactly one MAM query");
        }
    }

    private void test_exhausted_multi_room_mam_retries_do_not_spin() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            Jid first_room = new Jid(
                "retry-a@conference.example.test");
            Jid second_room = new Jid(
                "retry-b@conference.example.test");
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                first_room, conversation.nickname);
            stream.add_joinable_room_for_tests(second_room,
                conversation.nickname);
            stream.disco_mam = true;
            stream.auto_mam_error_condition =
                Xmpp.ErrorStanza.CONDITION_SERVICE_UNAVAILABLE;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            attach_account_module_for_tests<
                Xmpp.MessageArchiveManagement.Module>(stream_interactor,
                    account, stream,
                    Xmpp.MessageArchiveManagement.Module.IDENTITY);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_exhausted_multi_room_mam_retry_audit.begin(muc_manager,
                account, first_room, second_room, conversation.nickname,
                stream, (obj, res) => {
                    try {
                        run_exhausted_multi_room_mam_retry_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(15, () => {
                timeout_id = 0;
                failure = "timed out waiting for exhausted multi-room MAM retries";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_exhausted_multi_room_mam_retry_audit(
            MucManager muc_manager, Account account, Jid first_room,
            Jid second_room, string nick, MucManagerAuditStream stream)
            throws Error {
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            first_room, nick, null, true);
        validate_join_result(joined, "first exhausted-retry room join");
        joined = yield muc_manager.join(account, second_room, nick, null, true);
        validate_join_result(joined, "second exhausted-retry room join");

        // One initial IQ plus the productive MAX_ATTEMPTS=3 retries per room.
        const int EXPECTED_IQS_PER_ROOM = 4;
        bool retry_deadline = false;
        uint retry_timeout_id = 0;
        retry_timeout_id = Timeout.add_seconds(12, () => {
            retry_timeout_id = 0;
            retry_deadline = true;
            return Source.REMOVE;
        });
        while ((stream.get_mam_iq_count_for_room(first_room) <
                    EXPECTED_IQS_PER_ROOM ||
                stream.get_mam_iq_count_for_room(second_room) <
                    EXPECTED_IQS_PER_ROOM) && !retry_deadline) {
            yield wait_muc_audit_low_tick();
        }
        if (retry_timeout_id != 0) Source.remove(retry_timeout_id);

        int first_count = stream.get_mam_iq_count_for_room(first_room);
        int second_count = stream.get_mam_iq_count_for_room(second_room);
        if (first_count != EXPECTED_IQS_PER_ROOM ||
                second_count != EXPECTED_IQS_PER_ROOM ||
                !muc_manager.has_pending_muc_mam_sync_for_tests(account,
                    first_room) ||
                !muc_manager.has_pending_muc_mam_sync_for_tests(account,
                    second_room) ||
                muc_manager.has_muc_mam_retry_scheduled_for_tests(account,
                    first_room) ||
                muc_manager.has_muc_mam_retry_scheduled_for_tests(account,
                    second_room)) {
            throw new IOError.FAILED(
                "both MAM rooms must stop after their independent retry budgets are exhausted");
        }

        // Both exhausted intents deliberately remain pending.  They must not
        // wake each other through the account-serial resume loop.
        yield wait_muc_audit_delay(1500);
        if (stream.get_mam_iq_count_for_room(first_room) != first_count ||
                stream.get_mam_iq_count_for_room(second_room) != second_count ||
                muc_manager.has_muc_mam_retry_scheduled_for_tests(account,
                    first_room) ||
                muc_manager.has_muc_mam_retry_scheduled_for_tests(account,
                    second_room)) {
            throw new IOError.FAILED(
                "exhausted pending MAM rooms spun or scheduled another IQ");
        }
    }

    private void test_mam_retry_state_cleans_up_after_part_and_left() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            Jid active_room = new Jid(
                "active-retry@conference.example.test");
            Jid retry_room = new Jid(
                "scheduled-retry@conference.example.test");
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                active_room, conversation.nickname);
            stream.add_joinable_room_for_tests(retry_room,
                conversation.nickname);
            stream.disco_mam = true;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            attach_account_module_for_tests<
                Xmpp.MessageArchiveManagement.Module>(stream_interactor,
                    account, stream,
                    Xmpp.MessageArchiveManagement.Module.IDENTITY);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_mam_retry_leave_reset_audit.begin(muc_manager, account,
                active_room, retry_room, conversation.nickname, stream,
                (obj, res) => {
                    try {
                        run_mam_retry_leave_reset_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(15, () => {
                timeout_id = 0;
                failure = "timed out waiting for MAM retry leave/reset audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_mam_retry_leave_reset_audit(
            MucManager muc_manager, Account account, Jid active_room,
            Jid retry_room, string nick, MucManagerAuditStream stream)
            throws Error {
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            active_room, nick, null, true);
        validate_join_result(joined, "active MAM leave audit join");
        int ticks = 0;
        while (stream.get_mam_iq_count_for_room(active_room) < 1 &&
                ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.get_mam_iq_count_for_room(active_room) != 1) {
            throw new IOError.FAILED(
                "active leave audit did not start its held MAM IQ");
        }

        muc_manager.part(account, active_room);
        Xmpp.MessageArchiveManagement.Flag mam_flag =
            Xmpp.MessageArchiveManagement.Flag.get_flag(stream);
        ticks = 0;
        while (!mam_flag.active_query_ids.is_empty && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (!mam_flag.active_query_ids.is_empty ||
                muc_manager.has_pending_muc_mam_sync_for_tests(account,
                    active_room) ||
                muc_manager.has_muc_mam_retry_scheduled_for_tests(account,
                    active_room)) {
            throw new IOError.FAILED(
                "part during active MAM must cancel owner, pending intent and retry source");
        }

        stream.auto_mam_error_condition =
            Xmpp.ErrorStanza.CONDITION_SERVICE_UNAVAILABLE;
        joined = yield muc_manager.join(account, retry_room, nick, null, true);
        validate_join_result(joined, "scheduled MAM retry join");
        ticks = 0;
        while (!muc_manager.has_muc_mam_retry_scheduled_for_tests(account,
                retry_room) && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.get_mam_iq_count_for_room(retry_room) != 1 ||
                !muc_manager.has_pending_muc_mam_sync_for_tests(account,
                    retry_room) ||
                !muc_manager.has_muc_mam_retry_scheduled_for_tests(account,
                    retry_room)) {
            throw new IOError.FAILED(
                "scheduled leave audit did not establish its first retry budget entry");
        }

        muc_manager.left(account, retry_room);
        int retry_baseline = stream.get_mam_iq_count_for_room(retry_room);
        if (muc_manager.has_pending_muc_mam_sync_for_tests(account,
                    retry_room) ||
                muc_manager.has_muc_mam_retry_scheduled_for_tests(account,
                    retry_room)) {
            throw new IOError.FAILED(
                "left during scheduled retry must clear pending intent and timeout source");
        }
        yield wait_muc_audit_delay(1500);
        if (stream.get_mam_iq_count_for_room(retry_room) != retry_baseline) {
            throw new IOError.FAILED(
                "a retry source survived part/left cleanup");
        }
    }


    private void test_custom_history_period_scope() {
        with_active_muc((si, account, conversation) => {
            Database database = get_muc_audit_database();
            MucManager manager = si.get_module<MucManager>(MucManager.IDENTITY);
            var sibling = si.get_module<ConversationManager>(ConversationManager.IDENTITY)
                .create_conversation(new Jid("sibling@conference.example.test"), account, Conversation.Type.GROUPCHAT);
            var other_account = new Account(new Jid("other@example.test"), "secret");
            other_account.persist(database);
            var other = new Conversation(conversation.counterpart, other_account, Conversation.Type.GROUPCHAT);
            other.persist(database);
            if (conversation.muc_history_days != 0 || !manager.set_muc_history_days(conversation, 365) ||
                    !manager.set_muc_history_days(sibling, 1) || !manager.set_muc_history_days(other, 7)) {
                throw new IOError.FAILED("offline group-period save failed or default was not Auto");
            }
            if (manager.request_muc_history_refresh(conversation) != MucHistoryRefreshResult.PENDING_JOIN ||
                    manager.set_muc_history_days(conversation, -1) || manager.set_muc_history_days(conversation, 366) ||
                    conversation.muc_history_days != 365) throw new IOError.FAILED("offline/invalid period handling changed a valid preference");
            foreach (Conversation target in new Conversation[] { conversation, sibling, other }) {
                Qlite.Row row = database.conversation.select().with<int>(database.conversation.id, "=", target.id).single().row().inner;
                var reloaded = new Conversation.from_row(database, row);
                if (reloaded.muc_history_days != target.muc_history_days) throw new IOError.FAILED("period did not persist with its account/room identity");
            }
            if (!manager.set_muc_history_days(conversation, 0) || conversation.muc_history_days != 0 ||
                    sibling.muc_history_days != 1 || other.muc_history_days != 7) throw new IOError.FAILED("Auto reset altered sibling account/room preferences");
            var direct = new Conversation(new Jid("bob@example.test"), account, Conversation.Type.CHAT);
            direct.persist(database);
            var pm = new Conversation(conversation.counterpart.with_resource("bob"), account, Conversation.Type.GROUPCHAT_PM);
            pm.persist(database);
            var unpersisted = new Conversation(new Jid("unpersisted@conference.example.test"), account, Conversation.Type.GROUPCHAT);
            if (manager.set_muc_history_days(direct, 30) || manager.set_muc_history_days(pm, 30) ||
                    manager.set_muc_history_days(unpersisted, 30)) throw new IOError.FAILED("non-room or unpersisted target accepted a group period");
            Qlite.Row clone_row = database.conversation.select().with<int>(database.conversation.id, "=", conversation.id).single().row().inner;
            var clone = new Conversation.from_row(database, clone_row);
            ulong clone_handler = clone.notify["muc-history-days"].connect(() => {
                // id is a writable public property; the private-set peer
                // address must not be changed through GObject reflection.
                clone.id = sibling.id;
            });
            bool rebound_saved = manager.set_muc_history_days(clone, 90);
            SignalHandler.disconnect(clone, clone_handler);
            Qlite.Row sibling_row = database.conversation.select().with<int>(database.conversation.id, "=", sibling.id).single().row().inner;
            if (rebound_saved || sibling.muc_history_days != 1 || (int) sibling_row[database.conversation.muc_history_days] != 1) throw new IOError.FAILED("period notify changed the durable ID without rejecting or preserving the sibling owner");
            int stale_id = conversation.id;
            database.conversation.delete().with<int>(database.conversation.id, "=", stale_id).perform();
            var replacement = new Conversation(conversation.counterpart, account, Conversation.Type.GROUPCHAT);
            replacement.persist(database);
            if (replacement.id == stale_id || manager.set_muc_history_days(conversation, 30) ||
                    manager.request_muc_history_refresh(conversation) != MucHistoryRefreshResult.UNAVAILABLE ||
                    replacement.muc_history_days != 0) throw new IOError.FAILED("deleted/replaced conversation accepted a stale dialog action");
            database.account.delete().with<int>(database.account.id, "=", other_account.id).perform();
            if (manager.set_muc_history_days(other, 30) ||
                    manager.request_muc_history_refresh(other) != MucHistoryRefreshResult.UNAVAILABLE) throw new IOError.FAILED("removed durable account accepted a history action");
        });
    }

    private static void downgrade_history_audit_conversation_schema(
            Database database, long version) throws Error {
        // Rebuild with the actual historical table definition: supported
        // older SQLite/SQLCipher runtimes do not implement DROP COLUMN.
        // Preserve row IDs, keys and defaults while omitting only v56 data.
        database.exec("ALTER TABLE conversation RENAME TO conversation_period_post56_fixture");
        database.conversation.create_table_at_version(version);
        database.exec("""
INSERT INTO conversation (
    id, account_id, jid_id, resource, active, active_last_changed,
    last_active, type, encryption, read_up_to, read_up_to_item,
    notification, send_typing, send_marker, pinned, history_cleared_at,
    message_expiry_seconds, muc_pm_peer_identity)
SELECT id, account_id, jid_id, resource, active, active_last_changed,
    last_active, type, encryption, read_up_to, read_up_to_item,
    notification, send_typing, send_marker, pinned, history_cleared_at,
    message_expiry_seconds, muc_pm_peer_identity
FROM conversation_period_post56_fixture;
DROP TABLE conversation_period_post56_fixture;
""");
    }

    private static void downgrade_history_audit_message_schema(
            Database database, long version) throws Error {
        // A v54/v55 fixture must omit later mention provenance as well. Use
        // the real historical schema rather than DROP COLUMN, which older
        // supported SQLite/SQLCipher versions do not implement.
        database.exec("ALTER TABLE message RENAME TO message_history_post57_fixture");
        database.message.create_table_at_version(version);
        database.exec("""
INSERT INTO message (
    id, stanza_id, server_id, sender_stanza_id, stable_id, stable_id_by,
    account_id, counterpart_id, counterpart_resource, our_resource,
    direction, type, time, local_time, body, encryption, encryption_protocol,
    decryption_failed, encryption_time_mismatch, marked, markable)
SELECT id, stanza_id, server_id, sender_stanza_id, stable_id, stable_id_by,
    account_id, counterpart_id, counterpart_resource, our_resource,
    direction, type, time, local_time, body, encryption, encryption_protocol,
    decryption_failed, encryption_time_mismatch, marked, markable
FROM message_history_post57_fixture;
DROP TABLE message_history_post57_fixture;
""");
        if (database.query_column_checked(
                "SELECT name FROM pragma_table_info('message') WHERE name = ?",
                { "mention_state" }).length != 0) {
            throw new IOError.FAILED(
                "historical message fixture still contains schema57 mention provenance");
        }
    }

    private void test_v55_history_period_migration() {
        string temp = "";
        string path = "";
        Database? database = null;
        try {
            // Earlier CSPRNG audit cases seed GLib.Random deliberately. A UUID
            // from that RNG can reuse an aborted fixture on a later full run.
            temp = DirUtils.make_tmp("dinox-history-v55-XXXXXX");
            path = Path.build_filename(temp, "core.db");
            database = new Database(path, "history-period-migration");
            var account = new Account(new Jid("alice@example.test"), "secret"); account.persist((!) database);
            var room = new Jid("room@conference.example.test");
            var conversation = new Conversation(room, account, Conversation.Type.GROUPCHAT);
            conversation.persist((!) database);
            int id = conversation.id;
            int range_id = insert_history_audit_range((!) database, account, room, "retained", 1000, 2000);
            downgrade_history_audit_conversation_schema((!) database, 55);
            downgrade_history_audit_message_schema((!) database, 55);
            rebuild_account_fixture_at_version((!) database, 55);
            ((!) database).exec("UPDATE _meta SET int_val = 55 WHERE name = 'version'");
            ((!) database).close(); database = null;
            database = new Database(path, "history-period-migration");
            Qlite.Row row = ((!) database).conversation.select().with<int>(((!) database).conversation.id, "=", id).single().row().inner;
            var loaded = new Conversation.from_row((!) database, row);
            if (loaded.muc_history_days != 0 || ((!) database).mam_catchup.select().with<int>(((!) database).mam_catchup.id, "=", range_id).count() != 1) {
                throw new IOError.FAILED("schema56 did not default to Auto or unnecessarily invalidated schema55 coverage");
            }
            loaded.muc_history_days = 365;
            ((!) database).close(); database = null;
            database = new Database(path, "history-period-migration");
            row = ((!) database).conversation.select().with<int>(((!) database).conversation.id, "=", id).single().row().inner;
            loaded = new Conversation.from_row((!) database, row);
            if (loaded.muc_history_days != 365 || ((!) database).mam_catchup.select().with<int>(((!) database).mam_catchup.id, "=", range_id).count() != 1) {
                throw new IOError.FAILED("period or existing coverage did not survive reopening schema56");
            }
        } catch (Error e) { fail_if_reached("Unexpected history-period migration error: " + e.message); }
        finally {
            if (database != null) ((!) database).close();
            if (temp != "") cleanup_muc_test_dir(temp, path);
        }
    }

    private void test_custom_history_window(int days, int restriction) {
        with_active_muc((si, account, original) => {
            Database database = get_muc_audit_database();
            si.add_module(new ContentItemStore.for_tests(si, database));
            HistorySync history = si.get_module<MessageProcessor>(MessageProcessor.IDENTITY).history_sync;
            history.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream(si, account, original.counterpart, original.nickname);
            stream.disco_mam = true; stream.defer_disco_info = true;
            var loop = new MainLoop(); string? failure = null;
            run_custom_history_window.begin(si, history, account, stream, days, restriction, (obj, response) => {
                try { run_custom_history_window.end(response); } catch (Error e) { failure = e.message; } loop.quit();
            });
            uint timeout = 0;
            timeout = Timeout.add_seconds(5, () => {
                timeout = 0;
                failure = "custom history window audit timed out (join presence=%d, MAM IQ=%d)".printf(stream.join_presence_count, stream.mam_iq_count);
                loop.quit(); return Source.REMOVE;
            });
            loop.run();
            if (timeout != 0) Source.remove(timeout);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_custom_history_window(StreamInteractor si, HistorySync history, Account account,
            MucManagerAuditStream stream, int days, int restriction) throws Error {
        var room = new Jid("fresh-period@conference.example.test");
        stream.add_joinable_room_for_tests(room, "alice");
        MucManager manager = si.get_module<MucManager>(MucManager.IDENTITY);
        validate_join_result(yield manager.join(account, room, "alice", null, false), "first room period join");
        Conversation? conversation = si.get_module<ConversationManager>(ConversationManager.IDENTITY).get_conversation(room, account, Conversation.Type.GROUPCHAT);
        if (conversation == null) throw new IOError.FAILED("first join did not create the period target");
        ((!) conversation).encryption = Encryption.NONE;
        DateTime now = new DateTime.now_utc();
        int64 expected_floor = days > 0
            ? now.add_days(-days).to_unix()
            : history.sync_not_before.to_unix();
        if (restriction == 1) {
            history.set_panic_sync_floor(now.add_days(-90));
            expected_floor = now.add_days(-90).to_unix();
            if (history.sync_not_before.to_unix() != expected_floor) throw new IOError.FAILED("actual panic setter changed legacy Auto semantics");
        } else if (restriction == 2) {
            ((!) conversation).history_cleared_at = now.add_days(-2); expected_floor = now.add_days(-2).to_unix();
        } else if (restriction == 3) {
            ((!) conversation).history_cleared_at = now.add_days(-2);
            ((!) conversation).message_expiry_seconds = 3600; expected_floor = now.add_seconds(-3600).to_unix();
        }
        if (!manager.set_muc_history_days((!) conversation, days) || stream.mam_iq_count != 0) throw new IOError.FAILED("saving custom days started a request before Load/normal join sync");
        stream.release_held_disco_successes();
        yield wait_for_history_audit_request(stream, 1);
        DateTime? actual_floor = history_audit_request_start(stream, 0);
        if (actual_floor == null || ((!) actual_floor).to_unix() < expected_floor || ((!) actual_floor).to_unix() > expected_floor + 5) {
            throw new IOError.FAILED("actual first MAM request ignored custom/Auto/panic/clear/expiry window");
        }
        stream.emit_mam_archived_message(0, "period-current", Xmpp.Xep.DateTimeProfiles.to_datetime(now));
        stream.emit_mam_fin(0, false, "period-current");
        if (days > 0) {
            yield wait_for_history_audit_request(stream, 2);
            actual_floor = history_audit_request_start(stream, 1);
            if (actual_floor == null || ((!) actual_floor).to_unix() < expected_floor || ((!) actual_floor).to_unix() > expected_floor + 5) throw new IOError.FAILED("custom first join did not FULL-backfill the requested window");
            if (history.current_catchup_id[account].has_key(room)) throw new IOError.FAILED("custom cursor published before the older page completed");
            stream.emit_mam_archived_message(1, "period-older", Xmpp.Xep.DateTimeProfiles.to_datetime(new DateTime.from_unix_utc(expected_floor + 60)), "older requested group history");
            stream.emit_mam_fin(1, true, "period-older");
            int ticks = 0;
            while (!history.current_catchup_id[account].has_key(room) && ticks++ < 200) yield wait_muc_audit_low_tick();
            if (!history.current_catchup_id[account].has_key(room) || stream.mam_iq_count != 2) throw new IOError.FAILED("custom FULL window did not finish its real older page");
            Qlite.Row row = get_history_audit_range(get_muc_audit_database(), account, room);
            if ((long) row[get_muc_audit_database().mam_catchup.from_time] < expected_floor || (bool) row[get_muc_audit_database().mam_catchup.from_end]) throw new IOError.FAILED("custom bounded coverage crossed the hard floor or exhausted all history");
        } else {
            for (int i = 0; i < 40; i++) yield wait_muc_audit_low_tick();
            if (stream.mam_iq_count != 1) throw new IOError.FAILED("Auto first join changed its original latest-only behavior");
        }
    }

    private void test_muc_reload_unavailable(int variant) {
        with_active_muc((si, account, room) => {
            var history = si.get_module<MessageProcessor>(MessageProcessor.IDENTITY).history_sync;
            history.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream(si, account, room.counterpart, room.nickname);
            stream.disco_members_only = true;
            stream.disco_non_anonymous = true;
            var loop = new MainLoop();
            string? failure = null;
            run_muc_reload_unavailable.begin(si, account, room, stream, variant, (obj, res) => {
                try { run_muc_reload_unavailable.end(res); }
                catch (Error error) { failure = error.message; }
                loop.quit();
            });
            uint timeout = 0;
            timeout = Timeout.add_seconds(15, () => {
                timeout = 0; failure = "unsupported private MUC reload did not finish";
                loop.quit(); return Source.REMOVE;
            });
            loop.run();
            if (timeout != 0) Source.remove(timeout);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_muc_reload_unavailable(StreamInteractor si, Account account,
            Conversation room, MucManagerAuditStream stream, int variant) throws Error {
        var manager = si.get_module<MucManager>(MucManager.IDENTITY);
        validate_join_result(yield manager.join(account, room.counterpart,
            room.nickname, null, false), "unsupported private MUC join");
        for (int i = 0; i < 30; i++) yield wait_muc_audit_low_tick();
        int completions = 0;
        HistorySync.FetchResult outcome = HistorySync.FetchResult.ERROR;
        MucHistoryRefreshResult replacement = MucHistoryRefreshResult.UNAVAILABLE;
        ulong handler = manager.history_refresh_finished.connect((target, result) => {
            if (target != room) return;
            completions++; outcome = result;
            if (variant == 2 && completions == 1 && result == HistorySync.FetchResult.UNAVAILABLE) {
                stream.disco_mam = true;
                replacement = manager.request_muc_history_refresh(room);
            }
        });
        try {
            stream.defer_disco_info = variant == 1;
            if (manager.request_muc_history_refresh(room) != MucHistoryRefreshResult.QUEUED)
                throw new IOError.FAILED("unsupported room reload was not queued for discovery");
            if (variant == 1) {
                while (!manager.has_muc_mam_retry_scheduled_for_tests(account, room.counterpart))
                    yield wait_muc_audit_delay(10);
                stream.release_held_disco_successes();
            }
            for (int i = 0; i < 100 && completions == 0; i++) yield wait_muc_audit_low_tick();
            if (completions != 1 || outcome != HistorySync.FetchResult.UNAVAILABLE)
                throw new IOError.FAILED("missing or wrong unavailable-archive completion");
            if (variant == 2) {
                if (replacement != MucHistoryRefreshResult.QUEUED)
                    throw new IOError.FAILED("completion observer could not replace the old intent");
                yield wait_for_history_audit_request(stream, 1);
                stream.emit_mam_fin(0, true, null);
                for (int i = 0; i < 100 && completions < 2; i++) yield wait_muc_audit_low_tick();
                if (completions != 2 || outcome != HistorySync.FetchResult.SUCCESS)
                    throw new IOError.FAILED("old completion removed the replacement report");
            } else if (stream.mam_iq_count != 0) {
                throw new IOError.FAILED("unsupported archive was queried");
            }
            if (manager.has_pending_muc_mam_sync_for_tests(account, room.counterpart) ||
                    manager.has_muc_mam_retry_scheduled_for_tests(account, room.counterpart))
                throw new IOError.FAILED("completed unavailable intent left a pending retry");
        } finally {
            SignalHandler.disconnect(manager, handler);
        }
    }

    private void test_manual_history_restore(bool clear_again) {
        with_active_muc((si, account, conversation) => {
            Database database = get_muc_audit_database();
            si.add_module(new ContentItemStore.for_tests(si, database));
            HistorySync history = si.get_module<MessageProcessor>(MessageProcessor.IDENTITY).history_sync;
            history.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream(si, account, conversation.counterpart, conversation.nickname);
            var loop = new MainLoop();
            string? failure = null;
            run_manual_history_restore.begin(si, account, conversation,
                history, stream, clear_again, (obj, response) => {
                    try { run_manual_history_restore.end(response); }
                    catch (Error error) { failure = error.message; }
                    loop.quit();
                });
            uint timeout = 0;
            timeout = Timeout.add_seconds(5, () => {
                timeout = 0;
                failure = "manual history restore timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout != 0) Source.remove(timeout);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_manual_history_restore(StreamInteractor si,
            Account account, Conversation conversation, HistorySync history,
            MucManagerAuditStream stream, bool clear_again) throws Error {
        Database database = get_muc_audit_database();
        MucManager manager = si.get_module<MucManager>(MucManager.IDENTITY);
        ConversationManager conversations = si.get_module<ConversationManager>(ConversationManager.IDENTITY);
        conversation.encryption = Encryption.NONE;
        validate_join_result(yield manager.join(account, conversation.counterpart,
            conversation.nickname, null, false), "restore initial join");
        for (int i = 0; i < 30; i++) yield wait_muc_audit_low_tick();
        DateTime now = new DateTime.now_utc();
        var sibling = new Jid("sibling@conference.example.test");
        int sibling_range = insert_history_audit_range(database, account,
            sibling, "sibling", (long) now.add_days(-20).to_unix(),
            (long) now.to_unix(), true);
        int own_range = insert_history_audit_range(database, account,
            conversation.counterpart, "already-loaded",
            (long) now.add_days(-20).to_unix(), (long) now.to_unix(), true);
        history.current_catchup_id[account][sibling] = sibling_range;
        history.current_catchup_id[account][conversation.counterpart] = own_range;
        conversations.clear_conversation_history(conversation, false);
        DateTime? cleared = conversation.history_cleared_at;
        manager.part(account, conversation.counterpart);
        validate_join_result(yield manager.join(account, conversation.counterpart,
            conversation.nickname, null, false), "restore rejoin");
        if (cleared == null || conversation.history_cleared_at == null ||
                ((!) conversation.history_cleared_at).compare((!) cleared) != 0 ||
                database.message.select().count() != 0) {
            throw new IOError.FAILED("ordinary rejoin undid local history clearing");
        }
        stream.disco_mam = true;
        if (manager.request_muc_history_refresh(conversation) != MucHistoryRefreshResult.QUEUED) {
            throw new IOError.FAILED("manual restore was not queued");
        }
        yield wait_for_history_audit_request(stream, 1);
        DateTime? floor = history_audit_request_start(stream, 0);
        if (floor == null || ((!) floor).compare(now.add_days(-10)) > 0) {
            throw new IOError.FAILED("manual restore still clamps to the local clear/rejoin timestamp");
        }
        if (clear_again) conversations.clear_conversation_history(conversation, false);
        stream.emit_mam_archived_message(0, "already-loaded-last",
            Xmpp.Xep.DateTimeProfiles.to_datetime(now.add_days(-1)), "newer restored history");
        stream.emit_mam_fin(0, false, "already-loaded-last");
        yield wait_for_history_audit_request(stream, 2);
        stream.emit_mam_archived_message(1, "restored-older",
            Xmpp.Xep.DateTimeProfiles.to_datetime(now.add_days(-10)), "older restored history");
        stream.emit_mam_fin(1, true, "restored-older");
        for (int i = 0; i < 80; i++) yield wait_muc_audit_low_tick();
        int expected = clear_again ? 0 : 2;
        if (database.message.select().count() != expected ||
                si.get_module<ContentItemStore>(ContentItemStore.IDENTITY)
                    .get_n_latest(conversation, 10).size != expected ||
                (clear_again && conversation.history_cleared_at == null) ||
                (!clear_again && conversation.history_cleared_at != null)) {
            throw new IOError.FAILED("manual restore failed to persist history or bypassed a newer clear");
        }
        if (database.mam_catchup.select().with<int>(database.mam_catchup.id,
                "=", sibling_range).count() != 1 ||
                history.current_catchup_id[account][sibling] != sibling_range) {
            throw new IOError.FAILED("manual restore modified another room's archive state");
        }
    }

    private void test_custom_history_refresh() {
        with_active_muc((si, account, conversation) => {
            Database database = get_muc_audit_database();
            si.add_module(new ContentItemStore.for_tests(si, database));
            HistorySync history = si.get_module<MessageProcessor>(MessageProcessor.IDENTITY).history_sync;
            history.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream(si, account, conversation.counterpart, conversation.nickname);
            var loop = new MainLoop(); string? failure = null;
            run_custom_history_refresh.begin(si, history, account, conversation, stream, (obj, response) => {
                try { run_custom_history_refresh.end(response); } catch (Error e) { failure = e.message; } loop.quit();
            });
            uint timeout = 0;
            timeout = Timeout.add_seconds(5, () => {
                timeout = 0;
                failure = "explicit history refresh audit timed out (join presence=%d, MAM IQ=%d)".printf(stream.join_presence_count, stream.mam_iq_count);
                loop.quit(); return Source.REMOVE;
            });
            loop.run();
            if (timeout != 0) Source.remove(timeout);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_custom_history_refresh(StreamInteractor si, HistorySync history, Account account,
            Conversation conversation, MucManagerAuditStream stream) throws Error {
        MucManager manager = si.get_module<MucManager>(MucManager.IDENTITY);
        conversation.encryption = Encryption.NONE;
        validate_join_result(yield manager.join(account, conversation.counterpart, conversation.nickname, null, false), "explicit refresh original join");
        for (int i = 0; i < 30; i++) yield wait_muc_audit_low_tick();
        long now = (long) new DateTime.now_utc().to_unix();
        var sibling = new Jid("sibling@conference.example.test");
        int sibling_id = insert_history_audit_range(get_muc_audit_database(), account, sibling, "sibling", now - 10 * 86400, now - 7 * 86400);
        history.current_catchup_id[account][sibling] = sibling_id;
        insert_history_audit_range(get_muc_audit_database(), account, conversation.counterpart, "old", now - 10 * 86400, now - 7 * 86400);
        int enters = stream.join_presence_count;
        int exits = stream.unavailable_presence_count;
        if (!manager.set_muc_history_days(conversation, 365) || stream.mam_iq_count != 0) throw new IOError.FAILED("period save was not network-free");
        stream.disco_mam = true; stream.defer_disco_info = true;
        if (manager.request_muc_history_refresh(conversation) != MucHistoryRefreshResult.QUEUED ||
                manager.request_muc_history_refresh(conversation) != MucHistoryRefreshResult.QUEUED) throw new IOError.FAILED("rapid Load clicks were not safely queued");
        stream.release_held_disco_successes();
        yield wait_for_history_audit_request(stream, 1);
        if (!manager.set_muc_history_days(conversation, 1) || stream.mam_iq_count != 1) throw new IOError.FAILED("changing an in-flight period issued an implicit query");
        if (manager.request_muc_history_refresh(conversation) != MucHistoryRefreshResult.QUEUED) throw new IOError.FAILED("replacement Load request was not queued");
        yield wait_for_history_audit_request(stream, 2);
        DateTime? floor = history_audit_request_start(stream, 1);
        int64 expected = new DateTime.now_utc().add_days(-1).to_unix();
        if (floor == null || ((!) floor).to_unix() < expected - 5 || ((!) floor).to_unix() > expected + 5) throw new IOError.FAILED("replacement owner kept the superseded broad window");
        stream.emit_mam_archived_message(1, "replacement-current", Xmpp.Xep.DateTimeProfiles.to_datetime(new DateTime.now_utc()));
        stream.emit_mam_fin(1, false, "replacement-current");
        yield wait_for_history_audit_request(stream, 3);
        stream.emit_mam_archived_message(2, "replacement-older", Xmpp.Xep.DateTimeProfiles.to_datetime(new DateTime.from_unix_utc(expected + 60)), "replacement requested history");
        stream.emit_mam_fin(2, true, "replacement-older");
        int ticks = 0; while (!history.current_catchup_id[account].has_key(conversation.counterpart) && ticks++ < 200) yield wait_muc_audit_low_tick();
        if (!history.current_catchup_id[account].has_key(conversation.counterpart) ||
                history.current_catchup_id[account][sibling] != sibling_id || stream.join_presence_count != enters ||
                stream.unavailable_presence_count != exits || !manager.is_joined(conversation.counterpart, account)) throw new IOError.FAILED("Load disrupted joining or sibling-room history ownership");
    }
    private MucManagerAuditStream prepare_history_audit_stream(
            StreamInteractor stream_interactor, Account account, Jid room,
            string nickname) throws Error {
        var stream = new MucManagerAuditStream(new Jid("example.test"),
            room, nickname);
        attach_muc_stream_modules_for_tests(stream_interactor, account, stream);
        attach_account_module_for_tests<
            Xmpp.MessageArchiveManagement.Module>(stream_interactor,
                account, stream, Xmpp.MessageArchiveManagement.Module.IDENTITY);
        stream_interactor.connection_manager.set_connected_stream_for_tests(
            account, stream);
        stream_interactor.connection_manager.stream_attached_modules(
            account, stream);
        return stream;
    }

    private static Qlite.Row get_history_audit_range(Database database,
            Account account, Jid archive) throws Error {
        Qlite.RowOption row = database.mam_catchup.select()
            .with<int>(database.mam_catchup.account_id, "=", account.id)
            .with<string>(database.mam_catchup.server_jid, "=",
                archive.bare_jid.to_string())
            .order_by(database.mam_catchup.to_time, "DESC")
            .single().row();
        if (!row.is_present()) throw new IOError.FAILED(
            "history audit did not persist the expected archive range");
        return row.inner;
    }

    private static int insert_history_audit_range(Database database,
            Account account, Jid archive, string prefix, long from_time,
            long to_time, bool exhausted = false) {
        return (int) database.mam_catchup.insert()
            .value<int>(database.mam_catchup.account_id, account.id)
            .value<string>(database.mam_catchup.server_jid,
                archive.bare_jid.to_string())
            .value<string>(database.mam_catchup.from_id, prefix + "-first")
            .value<long>(database.mam_catchup.from_time, from_time)
            .value<bool>(database.mam_catchup.from_end, exhausted)
            .value<string>(database.mam_catchup.to_id, prefix + "-last")
            .value<long>(database.mam_catchup.to_time, to_time)
            .perform();
    }

    private static DateTime? history_audit_request_start(
            MucManagerAuditStream stream, int index) throws Error {
        StanzaNode request = stream.get_mam_request_for_tests(index);
        StanzaNode? query = request.get_subnode("query",
            Xmpp.MessageArchiveManagement.NS_URI);
        StanzaNode? form = query != null ? ((!) query).get_subnode("x",
            Xmpp.Xep.DataForms.NS_URI) : null;
        if (form == null) return null;
        foreach (StanzaNode field in ((!) form).get_subnodes("field",
                Xmpp.Xep.DataForms.NS_URI)) {
            if (field.get_attribute("var") != "start") continue;
            StanzaNode? value = field.get_subnode("value",
                Xmpp.Xep.DataForms.NS_URI);
            string? text = value != null ?
                ((!) value).get_string_content() : null;
            if (text == null) throw new IOError.FAILED(
                "history audit received an empty MAM start field");
            DateTime? start = Xmpp.Xep.DateTimeProfiles.parse_string((!) text);
            if (start == null) throw new IOError.FAILED(
                "history audit received an invalid MAM start timestamp");
            return start;
        }
        return null;
    }

    private async void wait_for_history_audit_request(
            MucManagerAuditStream stream, int count) throws Error {
        int ticks = 0;
        while (stream.mam_iq_count < count && ticks++ < 200) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.mam_iq_count != count) throw new IOError.FAILED(
            "history audit expected %d real MAM requests, received %d".printf(
                count, stream.mam_iq_count));
    }

    private async Qlite.Row? finish_history_audit_latest_page(
            HistorySync history, Account account, Jid archive,
            Qlite.Row? previous, DateTime? floor,
            MucManagerAuditStream stream, int request_index,
            string archive_id, DateTime timestamp) throws Error {
        bool done = false;
        Qlite.Row? result_row = null;
        HistorySync.FetchResult result = HistorySync.FetchResult.ERROR;
        var cancellable = new Cancellable();
        var cancellation = new HistorySync.FetchCancellation(cancellable);
        try {
            history.fetch_latest_page.begin(account, archive, previous,
                floor, cancellation, (obj, response) => {
                    result_row = history.fetch_latest_page.end(response,
                        out result);
                    done = true;
                });
            yield wait_for_history_audit_request(stream, request_index + 1);
            stream.emit_mam_archived_message(request_index, archive_id,
                Xmpp.Xep.DateTimeProfiles.to_datetime(timestamp));
            stream.emit_mam_fin(request_index, true, archive_id);
            int ticks = 0;
            while (!done && ticks++ < 200) yield wait_muc_audit_low_tick();
            if (!done || result != HistorySync.FetchResult.SUCCESS) {
                throw new IOError.FAILED(
                    "complete real MAM page did not settle successfully");
            }
            return result_row;
        } finally {
            if (!done) cancellable.cancel();
        }
    }

    private void test_complete_mam_range(bool existing, bool bounded) {
        with_active_muc((stream_interactor, account, conversation) => {
            Database database = get_muc_audit_database();
            HistorySync history = stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY).history_sync;
            history.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream(stream_interactor,
                account, conversation.counterpart, conversation.nickname);
            long now = (long) (new DateTime.now_utc()).to_unix();

            // Identical room JIDs on different accounts and a sibling room
            // must keep their own independent coverage, even when IDs overlap.
            var other_account = new Account(new Jid("other@example.test"),
                "history-audit-password");
            other_account.persist(database);
            var other_room = new Jid("other@conference.example.test");
            int sibling_room = insert_history_audit_range(database, account,
                other_room, "same-id", now - 4 * 86400, now - 3 * 86400, true);
            int sibling_account = insert_history_audit_range(database,
                other_account, conversation.counterpart, "same-id",
                now - 4 * 86400, now - 3 * 86400, true);
            Qlite.Row? previous = null;
            if (existing) {
                insert_history_audit_range(database, account,
                    conversation.counterpart, "existing",
                    now - 86400, now);
                previous = get_history_audit_range(database, account,
                    conversation.counterpart);
            }

            var loop = new MainLoop();
            string? failure = null;
            run_complete_mam_range.begin(history, account,
                conversation.counterpart, stream, previous, bounded, now,
                sibling_room, sibling_account, (obj, response) => {
                    try { run_complete_mam_range.end(response); }
                    catch (Error error) { failure = error.message; }
                    loop.quit();
                });
            uint timeout = Timeout.add_seconds(5, () => {
                failure = "complete MAM range audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_complete_mam_range(HistorySync history,
            Account account, Jid archive, MucManagerAuditStream stream,
            Qlite.Row? previous, bool bounded, long now,
            int sibling_room, int sibling_account) throws Error {
        Database database = get_muc_audit_database();
        DateTime? floor = bounded ? new DateTime.from_unix_utc(
            now - 2 * 86400) : null;
        yield finish_history_audit_latest_page(history, account, archive,
            previous, floor, stream, 0, "fresh-complete",
            new DateTime.from_unix_utc(now));
        Qlite.Row persisted = get_history_audit_range(database, account,
            archive);
        bool exhausted = persisted[database.mam_catchup.from_end];
        if (exhausted == bounded) throw new IOError.FAILED(
            bounded ? "a filtered complete page falsely exhausted the entire archive" :
            "an unfiltered complete archive page did not record true exhaustion");
        if ((string) persisted[database.mam_catchup.to_id] !=
                "fresh-complete") throw new IOError.FAILED(
            "the real complete response did not update its own archive cursor");
        DateTime? actual_start = history_audit_request_start(stream, 0);
        if ((actual_start != null) != bounded) throw new IOError.FAILED(
            "the exhaustion audit did not issue its intended filtered/unfiltered query");

        foreach (int id in new int[] { sibling_room, sibling_account }) {
            Qlite.Row row = database.mam_catchup.select()
                .with<int>(database.mam_catchup.id, "=", id).single().row().inner;
            if (!(bool) row[database.mam_catchup.from_end] ||
                    (string) row[database.mam_catchup.to_id] != "same-id-last" ||
                    (long) row[database.mam_catchup.to_time] != now - 3 * 86400) {
                throw new IOError.FAILED(
                    "one archive's completion changed sibling room/account coverage");
            }
        }
    }

    // Models the decryptor's output at the real reload/store boundary. Native
    // OMEMO and GPG tests cover the cryptography independently of this fixture.
    private class ReloadSummaryDecryptListener : MessageListener {
        private Encryption encryption;
        private string protocol;
        public ReloadSummaryDecryptListener(Encryption encryption, string protocol) {
            this.encryption = encryption;
            this.protocol = protocol;
        }
        public string[] dependencies = new string[] {};
        public override string action_group { get { return "DECRYPT"; } }
        public override string[] after_actions { get { return dependencies; } }
        public override async bool run(Entities.Message message,
                Xmpp.MessageStanza stanza, Conversation conversation) {
            message.encryption = encryption;
            message.encryption_protocol = protocol;
            if (stanza.body == "reload-failure" || stanza.body == "own-reload-failure") {
                message.encryption = Encryption.OMEMO;
                message.decryption_failed = true;
                message.body = stanza.body == "own-reload-failure" ? null
                    : "[This OMEMO message could not be decrypted]";
            } else if (stanza.body == "new-failure") {
                message.decryption_failed = true;
                message.body = encryption == Encryption.OMEMO
                    ? "[This OMEMO message could not be decrypted]" : "new protocol failure";
            }
            return false;
        }
    }

    private void test_reload_summary(bool group, int protocol, int variant = 0) {
        with_active_muc((si, account, room) => {
            Database database = get_muc_audit_database();
            si.add_module(new ContentItemStore.for_tests(si, database));
            var processor = si.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
            processor.history_sync.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream(si, account, room.counterpart, room.nickname);
            if (variant != 0) {
                stream.disco_members_only = true;
                stream.disco_non_anonymous = true;
            }
            var loop = new MainLoop(); string? failure = null;
            run_reload_summary.begin(si, account, room, stream, group, protocol, variant, (obj, res) => {
                try { run_reload_summary.end(res); }
                catch (Error error) { failure = error.message; }
                loop.quit();
            });
            uint timeout = 0;
            timeout = Timeout.add_seconds(8, () => {
                timeout = 0; failure = "reload summary timed out";
                loop.quit(); return Source.REMOVE;
            });
            loop.run();
            if (timeout != 0) Source.remove(timeout);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private int insert_summary_diagnostic(Database db, Conversation conversation, string id) {
        var stamp = new DateTime.now_utc().add_days(-1);
        var message = new Entities.Message("[This OMEMO message could not be decrypted]") {
            account = conversation.account, counterpart = conversation.counterpart,
            ourpart = conversation.account.bare_jid, stanza_id = id,
            type_ = Util.get_message_type_for_conversation(conversation),
            direction = Entities.Message.DIRECTION_RECEIVED,
            time = stamp, local_time = stamp, encryption = Encryption.OMEMO,
            decryption_failed = true
        };
        message.persist(db);
        return db.add_content_item(conversation, stamp, stamp, 1, message.id, false);
    }

    private async void receive_summary_message(MessageProcessor processor,
            Conversation conversation, string id, string body, bool archive) throws Error {
        var stanza = new Xmpp.MessageStanza(id);
        stanza.from = conversation.counterpart.with_resource("sender");
        stanza.to = conversation.account.bare_jid;
        stanza.type_ = conversation.type_ == Conversation.Type.GROUPCHAT
            ? Xmpp.MessageStanza.TYPE_GROUPCHAT : Xmpp.MessageStanza.TYPE_CHAT;
        stanza.body = body;
        if (archive) {
            var source = conversation.type_ == Conversation.Type.GROUPCHAT
                ? conversation.counterpart : conversation.account.bare_jid;
            stanza.add_flag(new Xmpp.MessageArchiveManagement.MessageFlag(source,
                new DateTime.now_utc(), id, "automatic-catchup"));
        }
        yield processor.run_pipeline_announce(conversation.account, stanza);
    }

    private async void run_reload_summary(StreamInteractor si, Account account,
            owned Conversation room, MucManagerAuditStream stream, bool group, int protocol, int variant) throws Error {
        var db = get_muc_audit_database();
        var manager = si.get_module<MucManager>(MucManager.IDENTITY);
        var conversations = si.get_module<ConversationManager>(ConversationManager.IDENTITY);
        var processor = si.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
        var store = si.get_module<ContentItemStore>(ContentItemStore.IDENTITY);
        var history = processor.history_sync;
        if (variant == 3) {
            // Older receive paths could leave a CHAT beside the real room.
            // Create it first, as a profile restored from that state would.
            var address = new Jid("private-shadow@conference.example.test");
            conversations.create_conversation(address, account, Conversation.Type.CHAT);
            room = conversations.create_conversation(address, account, Conversation.Type.GROUPCHAT);
            room.nickname = "alice";
            stream.add_joinable_room_for_tests(address, room.nickname);
        }
        if (group) {
            validate_join_result(yield manager.join(account, room.counterpart,
                room.nickname, null, false), "summary initial join");
            for (int i = 0; i < 30; i++) yield wait_muc_audit_low_tick();
        }
        var conversation = group ? room : conversations.create_conversation(
            new Jid("bob@example.test"), account, Conversation.Type.CHAT);
        conversation.encryption = protocol == 0 ? Encryption.OMEMO
            : protocol == 3 ? Encryption.NONE : Encryption.PGP;
        var decrypt = new ReloadSummaryDecryptListener(conversation.encryption,
            protocol == 2 ? "openpgp:xep0374" : protocol == 1 ? "openpgp:xep0027" : "fixture");
        processor.received_pipeline.connect(decrypt);
        ulong handler = 0;
        try {
            var sibling = conversations.create_conversation(new Jid("carol@example.test"), account, Conversation.Type.CHAT);
            int sibling_error = insert_summary_diagnostic(db, sibling, "sibling-old-error");
            int old_error = insert_summary_diagnostic(db, conversation, "old-error");
            stream.disco_mam = true;
            bool[] done = new bool[] {false};
            int completions = 0;
            HistorySync.FetchResult result = HistorySync.FetchResult.ERROR;
            if (group) {
                handler = manager.history_refresh_finished.connect((target, outcome) => {
                    if (target.id != conversation.id || target.account != account) return;
                    result = outcome; completions++; done[0] = true;
                });
                if (manager.request_muc_history_refresh(conversation) != MucHistoryRefreshResult.QUEUED)
                    throw new IOError.FAILED("room summary request was not queued");
            } else {
                history.refresh_direct_conversation.begin(conversation, (obj, res) => {
                    result = history.refresh_direct_conversation.end(res); completions++; done[0] = true;
                });
            }
            yield wait_for_history_audit_request(stream, 1);
            // These arrive while the explicit archive query is held. Neither
            // live delivery nor automatic offline catch-up owns its report.
            yield receive_summary_message(processor, conversation, "live-good", "new live text", false);
            yield receive_summary_message(processor, conversation, "offline-good", "new offline text", true);
            yield receive_summary_message(processor, conversation, "live-error", "new-failure", false);
            yield receive_summary_message(processor, conversation, "offline-error", "new-failure", true);
            string stamp = Xmpp.Xep.DateTimeProfiles.to_datetime(new DateTime.now_utc().add_hours(-1));
            stream.emit_mam_archived_message(0, "failed-a", stamp, "reload-failure");
            stream.emit_mam_archived_message(0, "failed-own", stamp, "own-reload-failure");
            if (variant != 2) stream.emit_mam_archived_message(0, "good-a", stamp, "restored text a");
            stream.emit_mam_fin(0, false, "failed-a");
            yield wait_for_history_audit_request(stream, 2);
            stream.emit_mam_archived_message(1, "failed-b", stamp, "reload-failure");
            if (variant != 2) stream.emit_mam_archived_message(1, "good-b", stamp, "restored text b");
            // Authenticated/plain user content equal to the old diagnostic
            // marker must survive without the local failure flag.
            if (variant != 2) stream.emit_mam_archived_message(1, "literal-marker", stamp,
                "[This OMEMO message could not be decrypted]");
            stream.emit_mam_fin(1, true, "failed-b");
            yield wait_for_direct_history_result(done);
            if (completions != 1 || result != HistorySync.FetchResult.SUCCESS_WITH_OMEMO_FAILURES)
                throw new IOError.FAILED("reload must return one summary across multiple pages");
            if (db.content_item.select().with<int>(db.content_item.id, "=", old_error).single().row()[db.content_item.hide] ||
                    db.content_item.select().with<int>(db.content_item.id, "=", sibling_error).single().row()[db.content_item.hide])
                throw new IOError.FAILED("reload hid an existing receive diagnostic");
            foreach (string archive_id in new string[] {"failed-a", "failed-own", "failed-b"}) {
                if (db.message.select().with<string>(db.message.server_id, "=", archive_id).count() != 0)
                    throw new IOError.FAILED("manual reload persisted a repeated failure placeholder");
            }
            int expected_messages = variant == 2 ? 5 : 8;
            if (store.get_n_latest(conversation, 30).size != expected_messages)
                throw new IOError.FAILED("live, automatic catch-up, restored, or literal messages disappeared");
            yield receive_summary_message(processor, conversation, "after-good", "new text after reload", false);
            yield receive_summary_message(processor, conversation, "after-error", "new-failure", false);
            if (store.get_n_latest(conversation, 30).size != expected_messages + 2)
                throw new IOError.FAILED("completed reload changed later message/error delivery");
        } finally {
            if (handler != 0) SignalHandler.disconnect(manager, handler);
            processor.received_pipeline.disconnect(decrypt);
        }
    }

    private class DirectHistoryAuditDecryptListener : MessageListener {
        public int calls { get; private set; default = 0; }
        private string[] dependencies = new string[] {};
        public DirectHistoryAuditDecryptListener(bool wait_for_hold = false) {
            if (wait_for_hold) dependencies = new string[] { "HISTORY_POLICY_HOLD" };
        }
        public override string action_group { get { return "DECRYPT"; } }
        public override string[] after_actions { get { return dependencies; } }
        public override async bool run(Entities.Message message,
                Xmpp.MessageStanza stanza, Conversation conversation) {
            calls++;
            return false;
        }
    }

    private static string? history_audit_request_field(MucManagerAuditStream stream,
            int index, string variable) throws Error {
        StanzaNode request = stream.get_mam_request_for_tests(index);
        StanzaNode? form = request.get_deep_subnode(
            Xmpp.MessageArchiveManagement.NS_URI + ":query",
            Xmpp.Xep.DataForms.NS_URI + ":x");
        if (form == null) return null;
        foreach (StanzaNode field in ((!) form).get_subnodes("field", Xmpp.Xep.DataForms.NS_URI)) {
            if (field.get_attribute("var") == variable) {
                return field.get_deep_string_content(Xmpp.Xep.DataForms.NS_URI + ":value");
            }
        }
        return null;
    }

    private void test_direct_history_refresh(int variant) {
        with_active_muc((si, account, room) => {
            Database database = get_muc_audit_database();
            si.add_module(new ContentItemStore.for_tests(si, database));
            MessageProcessor processor = si.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
            HistorySync history = processor.history_sync;
            history.auto_fetch_enabled = false;
            Conversation direct = si.get_module<ConversationManager>(ConversationManager.IDENTITY)
                .create_conversation(variant == 11 ? room.counterpart : new Jid("bob@example.test"), account, Conversation.Type.CHAT);
            direct.encryption = Encryption.NONE;
            var stream = prepare_history_audit_stream(si, account, room.counterpart, room.nickname);
            stream.disco_mam = variant != 9;
            stream.defer_disco_info = variant == 15;
            var decrypt = new DirectHistoryAuditDecryptListener(variant == 10);
            HistoryPolicyHoldListener? hold = variant == 10 ? new HistoryPolicyHoldListener() : null;
            if (hold != null) processor.received_pipeline.connect((!) hold);
            processor.received_pipeline.connect(decrypt);
            try {
                var loop = new MainLoop(); string? failure = null;
                run_direct_history_refresh.begin(si, processor, history, account, direct,
                    room, stream, decrypt, variant, hold, (obj, response) => {
                        try { run_direct_history_refresh.end(response); } catch (Error e) { failure = e.message; } loop.quit();
                    });
                uint timeout = 0;
                timeout = Timeout.add_seconds(5, () => {
                    timeout = 0;
                    failure = "direct targeted MAM audit timed out (join presence=%d, MAM IQ=%d)".printf(stream.join_presence_count, stream.mam_iq_count);
                    loop.quit(); return Source.REMOVE;
                });
                loop.run();
                if (timeout != 0) Source.remove(timeout);
                if (failure != null) throw new IOError.FAILED((!) failure);
            } finally {
                processor.resume_after_snapshot();
                if (hold != null) {
                    ((!) hold).release();
                    processor.received_pipeline.disconnect((!) hold);
                }
                processor.received_pipeline.disconnect(decrypt);
            }
        });
    }

    private async void wait_for_direct_history_result(bool[] done) throws Error {
        int ticks = 0; while (!done[0] && ticks++ < 200) yield wait_muc_audit_low_tick();
        if (!done[0]) throw new IOError.FAILED("targeted direct history did not finish");
    }

    private async void run_direct_history_refresh(StreamInteractor si,
            MessageProcessor processor, HistorySync history, Account account,
            Conversation direct, Conversation room, MucManagerAuditStream stream,
            DirectHistoryAuditDecryptListener decrypt, int variant,
            HistoryPolicyHoldListener? hold) throws Error {
        Database database = get_muc_audit_database();
        DateTime now = new DateTime.now_utc();
        int account_range = insert_history_audit_range(database, account,
            account.bare_jid, "global", (long) now.add_days(-10).to_unix(), (long) now.add_days(-7).to_unix());
        int room_range = insert_history_audit_range(database, account,
            room.counterpart, "room", (long) now.add_days(-5).to_unix(), (long) now.add_days(-3).to_unix(), true);
        history.current_catchup_id[account][account.bare_jid] = account_range;
        history.current_catchup_id[account][room.counterpart] = room_range;
        DateTime expected_floor = history.sync_not_before;
        if (variant == 9 || variant >= 13) {
            si.get_module<ConversationManager>(ConversationManager.IDENTITY)
                .clear_conversation_history(direct, false);
        }
        Conversation target = direct;
        if (variant == 16) {
            Qlite.Row row = database.conversation.select()
                .with<int>(database.conversation.id, "=", direct.id).single().row().inner;
            target = new Conversation.from_row(database, row);
        }
        if (variant == 6 || variant == 8) {
            history.set_panic_sync_floor(now.add_days(-3));
            expected_floor = now.add_days(-3);
        }
        if (variant == 8) {
            direct.history_cleared_at = now.add_days(-2);
            direct.message_expiry_seconds = 3600;
            expected_floor = now.add_seconds(-3600);
        }
        if (variant == 4) yield processor.pause_for_snapshot(null);
        bool[] done = new bool[] { false };
        HistorySync.FetchResult result = HistorySync.FetchResult.ERROR;
        history.refresh_direct_conversation.begin(target, (obj, response) => {
            result = history.refresh_direct_conversation.end(response); done[0] = true;
        });
        if (variant == 15) {
            for (int i = 0; i < 30; i++) yield wait_muc_audit_low_tick();
            si.get_module<ConversationManager>(ConversationManager.IDENTITY)
                .clear_conversation_history(direct, false);
            expected_floor = (!) direct.history_cleared_at;
            stream.release_held_disco_successes();
        }
        if (variant == 9) {
            yield wait_for_direct_history_result(done);
            if (result != HistorySync.FetchResult.UNAVAILABLE || stream.mam_iq_count != 0) throw new IOError.FAILED("unsupported direct archive claimed completion or queried MAM");
            if (direct.history_cleared_at == null) throw new IOError.FAILED("unsupported archive lifted the local clear boundary");
        } else {
            yield wait_for_history_audit_request(stream, 1);
            DateTime? actual_floor = history_audit_request_start(stream, 0);
            if (stream.get_mam_request_for_tests(0).get_attribute("to") != account.bare_jid.to_string() ||
                    history_audit_request_field(stream, 0, "with") != direct.counterpart.bare_jid.to_string() ||
                    actual_floor == null || ((!) actual_floor).to_unix() < expected_floor.to_unix() ||
                    ((!) actual_floor).to_unix() > expected_floor.to_unix() + 5) throw new IOError.FAILED("targeted direct request used wrong account/peer/privacy floor");
            if (variant == 14) {
                si.get_module<ConversationManager>(ConversationManager.IDENTITY)
                    .clear_conversation_history(direct, false);
            }
            if (variant == 1 || variant == 15) {
                stream.emit_mam_fin(0, true, null);
            } else if (variant == 17) {
                // Real 1:1 archives include delivery receipts and call signals.
                // A full page without visible bodies must not stop backfill.
                for (int i = 0; i < 50; i++) {
                    stream.emit_mam_archived_message(0, "control-%d".printf(i),
                        Xmpp.Xep.DateTimeProfiles.to_datetime(now));
                }
                stream.emit_mam_fin(0, false, "control-0");
                yield wait_for_history_audit_request(stream, 2);
                stream.emit_mam_archived_message(1, "older-visible-message",
                    Xmpp.Xep.DateTimeProfiles.to_datetime(now.add_days(-1)),
                    "older archived text");
                stream.emit_mam_fin(1, true, "older-visible-message");
            } else if (variant == 7) {
                Conversation other = si.get_module<ConversationManager>(ConversationManager.IDENTITY)
                    .create_conversation(new Jid("carol@example.test"), account, Conversation.Type.CHAT);
                other.encryption = Encryption.NONE;
                bool[] other_done = new bool[] { false }; bool[] replacement_done = new bool[] { false };
                HistorySync.FetchResult other_result = HistorySync.FetchResult.ERROR;
                HistorySync.FetchResult replacement_result = HistorySync.FetchResult.ERROR;
                history.refresh_direct_conversation.begin(other, (obj, response) => {
                    other_result = history.refresh_direct_conversation.end(response); other_done[0] = true;
                });
                yield wait_for_history_audit_request(stream, 2);
                history.refresh_direct_conversation.begin(direct, (obj, response) => {
                    replacement_result = history.refresh_direct_conversation.end(response); replacement_done[0] = true;
                });
                yield wait_for_history_audit_request(stream, 3);
                stream.emit_mam_archived_message(1, "other-contact", Xmpp.Xep.DateTimeProfiles.to_datetime(now), "other contact archive", "carol@example.test/phone");
                stream.emit_mam_fin(1, true, "other-contact");
                stream.emit_mam_archived_message(2, "replacement-contact", Xmpp.Xep.DateTimeProfiles.to_datetime(now), "replacement contact archive");
                stream.emit_mam_fin(2, true, "replacement-contact");
                yield wait_for_direct_history_result(other_done);
                yield wait_for_direct_history_result(replacement_done);
                if (other_result != HistorySync.FetchResult.SUCCESS || replacement_result != HistorySync.FetchResult.SUCCESS) throw new IOError.FAILED("direct replacement cancelled an unrelated contact or blocked its new owner");
            } else {
                DateTime stamp = variant == 6 ? expected_floor.add_seconds(-1)
                    : variant >= 13 ? now.add_days(-1) : now;
                string? from = null;
                if (variant == 5) from = "mallory@example.test/phone";
                else if (variant == 11) from = room.counterpart.with_resource("archivist").to_string();
                if (variant == 0) history.catchup_until_id[account] = "direct-known";
                stream.emit_mam_archived_message(0, "direct-known", Xmpp.Xep.DateTimeProfiles.to_datetime(stamp), "known direct archive", from);
                if (variant == 2) database.conversation.delete().with<int>(database.conversation.id, "=", direct.id).perform();
                stream.emit_mam_fin(0, variant != 0, "direct-known", variant == 12);
                if (variant == 3) {
                    var replacement = prepare_history_audit_stream(si, account, room.counterpart, room.nickname);
                    replacement.disco_mam = true;
                } else if (variant == 4) {
                    for (int i = 0; i < 30; i++) yield wait_muc_audit_low_tick();
                    if (done[0] || decrypt.calls != 0) throw new IOError.FAILED("direct request did not actually wait at the snapshot admission barrier");
                    database.conversation.delete().with<int>(database.conversation.id, "=", direct.id).perform();
                    processor.resume_after_snapshot();
                } else if (variant == 10) {
                    int ticks = 0;
                    while (!((!) hold).entered && ticks++ < 200) yield wait_muc_audit_low_tick();
                    if (!((!) hold).entered || done[0] || decrypt.calls != 0) throw new IOError.FAILED("direct pipeline did not actually wait before DECRYPT");
                    database.conversation.delete().with<int>(database.conversation.id, "=", direct.id).perform();
                    ((!) hold).release();
                } else if (variant == 0) {
                    yield wait_for_history_audit_request(stream, 2);
                    if (history_audit_request_field(stream, 1, "with") != "bob@example.test") throw new IOError.FAILED("older page lost its contact filter");
                    stream.emit_mam_archived_message(1, "direct-older", Xmpp.Xep.DateTimeProfiles.to_datetime(now.add_days(-5)), "older direct archive");
                    stream.emit_mam_fin(1, true, "direct-older");
                }
            }
            yield wait_for_direct_history_result(done);
            HistorySync.FetchResult expected = (variant == 2 || variant == 3 || variant == 4 || variant == 7 || variant == 10 || variant == 11)
                ? HistorySync.FetchResult.CANCELLED : ((variant == 5 || variant == 6 || variant == 12)
                    ? HistorySync.FetchResult.ERROR : HistorySync.FetchResult.SUCCESS);
            if (result != expected) throw new IOError.FAILED("targeted direct request returned the wrong final admission/result state");
            if (variant == 0) {
                bool[] repeated_done = new bool[] { false }; HistorySync.FetchResult repeated_result = HistorySync.FetchResult.ERROR;
                history.refresh_direct_conversation.begin(direct, (obj, response) => {
                    repeated_result = history.refresh_direct_conversation.end(response); repeated_done[0] = true;
                });
                yield wait_for_history_audit_request(stream, 3);
                stream.emit_mam_archived_message(2, "direct-known", Xmpp.Xep.DateTimeProfiles.to_datetime(now), "known direct archive");
                stream.emit_mam_fin(2, false, "direct-known");
                yield wait_for_history_audit_request(stream, 4);
                stream.emit_mam_archived_message(3, "direct-older", Xmpp.Xep.DateTimeProfiles.to_datetime(now.add_days(-5)), "older direct archive");
                stream.emit_mam_fin(3, true, "direct-older");
                yield wait_for_direct_history_result(repeated_done);
                if (repeated_result != HistorySync.FetchResult.SUCCESS || database.message.select().count() != 2) throw new IOError.FAILED("known direct page stopped backfill early or duplicated persisted messages");
            } else if (variant == 13 || variant == 16 || variant == 17) {
                if (database.message.select().count() != 1 || direct.history_cleared_at != null ||
                        si.get_module<ContentItemStore>(ContentItemStore.IDENTITY)
                            .get_n_latest(direct, 10).size != 1 ||
                        target.history_cleared_at != null) {
                    throw new IOError.FAILED("manual direct refresh did not restore locally cleared history");
                }
                Qlite.Row persisted = database.conversation.select()
                    .with<int>(database.conversation.id, "=", direct.id).single().row().inner;
                if (new Conversation.from_row(database, persisted).history_cleared_at != null) {
                    throw new IOError.FAILED("manual direct restore did not persist across restart");
                }
            } else if (variant == 14 || variant == 15) {
                if (database.message.select().count() != 0 || decrypt.calls != 0 ||
                        direct.history_cleared_at == null) {
                    throw new IOError.FAILED("manual direct restore bypassed a newer local clear");
                }
            } else if (variant == 1 || (variant >= 2 && variant <= 6) || variant == 10 || variant == 11 || variant == 12) {
                if (decrypt.calls != 0 || database.message.select().count() != 0) throw new IOError.FAILED("empty/stale/foreign/out-of-floor direct history reached DECRYPT or storage");
                if (variant == 4 && database.conversation.select().with<int>(database.conversation.id, "=", direct.id).count() != 0) throw new IOError.FAILED("snapshot-blocked history recreated its deleted target");
                if (variant == 11 && database.conversation.select().with<int>(database.conversation.type_, "=", (int) Conversation.Type.GROUPCHAT_PM).count() != 0) throw new IOError.FAILED("direct history entered the PM resolver and created a private thread before scope rejection");
            }
        }
        Qlite.Row global = database.mam_catchup.select().with<int>(database.mam_catchup.id, "=", account_range).single().row().inner;
        Qlite.Row muc = database.mam_catchup.select().with<int>(database.mam_catchup.id, "=", room_range).single().row().inner;
        if (database.mam_catchup.select().count() != 2 ||
                (string) global[database.mam_catchup.to_id] != "global-last" ||
                (long) global[database.mam_catchup.from_time] != now.add_days(-10).to_unix() ||
                (bool) global[database.mam_catchup.from_end] ||
                (string) muc[database.mam_catchup.to_id] != "room-last" ||
                !(bool) muc[database.mam_catchup.from_end]) throw new IOError.FAILED("targeted direct refresh wrote accountwide or MUC archive coverage");
        // A real stream attachment intentionally resets cursors; other cases
        // must preserve both unrelated live bindings throughout refresh.
        if (variant != 3 && (history.current_catchup_id[account][account.bare_jid] != account_range ||
                history.current_catchup_id[account][room.counterpart] != room_range)) throw new IOError.FAILED("targeted direct refresh invalidated unrelated live cursors");
    }

    private void test_account_archive_bounded_backfill() {
        with_active_muc((si, account, conversation) => {
            HistorySync history = si.get_module<MessageProcessor>(MessageProcessor.IDENTITY).history_sync;
            history.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream(si, account, conversation.counterpart, conversation.nickname);
            var loop = new MainLoop(); string? failure = null;
            run_account_archive_bounded_backfill.begin(history, account, stream, (obj, response) => {
                try { run_account_archive_bounded_backfill.end(response); } catch (Error e) { failure = e.message; } loop.quit();
            });
            uint timeout = 0;
            timeout = Timeout.add_seconds(5, () => {
                timeout = 0;
                failure = "account archive bounded completion audit timed out (join presence=%d, MAM IQ=%d)".printf(stream.join_presence_count, stream.mam_iq_count);
                loop.quit(); return Source.REMOVE;
            });
            loop.run();
            if (timeout != 0) Source.remove(timeout);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_account_archive_bounded_backfill(HistorySync history,
            Account account, MucManagerAuditStream stream) throws Error {
        long now = (long) new DateTime.now_utc().to_unix();
        Jid archive = account.bare_jid;
        yield finish_history_audit_latest_page(history, account, archive, null,
            new DateTime.from_unix_utc(now - 7 * 86400), stream, 0,
            "account-complete", new DateTime.from_unix_utc(now));
        StanzaNode request = stream.get_mam_request_for_tests(0);
        Qlite.Row row = get_history_audit_range(get_muc_audit_database(), account, archive);
        if (request.get_attribute("to") != account.bare_jid.to_string() ||
                (bool) row[get_muc_audit_database().mam_catchup.from_end]) {
            throw new IOError.FAILED("bounded 1:1-account archive completion incorrectly exhausted its whole archive");
        }
        yield complete_bounded_backfill(history, account, archive, stream, 1, now, 14);
        if (stream.mam_iq_count != 3 ||
                stream.get_mam_request_for_tests(2).get_attribute("to") != account.bare_jid.to_string()) {
            throw new IOError.FAILED("a wider 1:1-account window did not issue its real older-page query");
        }
    }

    private void test_bounded_backfill() {
        with_active_muc((stream_interactor, account, conversation) => {
            HistorySync history = stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY).history_sync;
            history.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream(stream_interactor,
                account, conversation.counterpart, conversation.nickname);
            var loop = new MainLoop();
            string? failure = null;
            run_bounded_backfill.begin(history, account,
                conversation.counterpart, stream, (obj, response) => {
                    try { run_bounded_backfill.end(response); }
                    catch (Error error) { failure = error.message; }
                    loop.quit();
                });
            uint timeout = Timeout.add_seconds(5, () => {
                failure = "bounded backward MAM audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_bounded_backfill(HistorySync history,
            Account account, Jid archive, MucManagerAuditStream stream)
            throws Error {
        long now = (long) (new DateTime.now_utc()).to_unix();
        insert_history_audit_range(get_muc_audit_database(), account,
            archive, "existing", now - 86400, now);
        yield complete_bounded_backfill(history, account, archive, stream,
            0, now, 7);
        yield complete_bounded_backfill(history, account, archive, stream,
            2, now, 14);
    }

    private async void complete_bounded_backfill(HistorySync history,
            Account account, Jid archive, MucManagerAuditStream stream,
            int first_request, long now, int days) throws Error {
        Database database = get_muc_audit_database();
        var floor = new DateTime.from_unix_utc(now - days * 86400);
        bool done = false;
        HistorySync.FetchResult result = HistorySync.FetchResult.ERROR;
        var cancellable = new Cancellable();
        try {
            history.fetch_everything.begin(account, archive,
                new HistorySync.FetchCancellation(cancellable), floor,
                (obj, response) => {
                    result = history.fetch_everything.end(response);
                    done = true;
                });
            yield wait_for_history_audit_request(stream, first_request + 1);
            string latest_id = "bounded-latest-%d".printf(first_request);
            stream.emit_mam_archived_message(first_request, latest_id,
                Xmpp.Xep.DateTimeProfiles.to_datetime(
                    new DateTime.from_unix_utc(now)));
            stream.emit_mam_fin(first_request, true, latest_id);
            yield wait_for_history_audit_request(stream, first_request + 2);
            DateTime? requested_floor = history_audit_request_start(stream,
                first_request + 1);
            if (requested_floor == null ||
                    ((!) requested_floor).to_unix() != floor.to_unix()) {
                throw new IOError.FAILED(
                    "backward catch-up did not request the explicit older date window");
            }
            string older_id = "bounded-older-%d".printf(first_request);
            stream.emit_mam_archived_message(first_request + 1, older_id,
                Xmpp.Xep.DateTimeProfiles.to_datetime(
                    new DateTime.from_unix_utc(now - (days - 1) * 86400)));
            stream.emit_mam_fin(first_request + 1, true, older_id);
            int ticks = 0;
            while (!done && ticks++ < 200) yield wait_muc_audit_low_tick();
            if (!done || result != HistorySync.FetchResult.SUCCESS) {
                throw new IOError.FAILED(
                    "bounded backward page did not settle successfully");
            }
            Qlite.Row row = get_history_audit_range(database, account, archive);
            if ((bool) row[database.mam_catchup.from_end] ||
                    (long) row[database.mam_catchup.from_time] !=
                        floor.to_unix() ||
                    (string) row[database.mam_catchup.from_id] != older_id) {
                throw new IOError.FAILED(
                    "bounded backward completion did not retain its date floor without global exhaustion");
            }
        } finally {
            if (!done) cancellable.cancel();
        }
    }

    private void test_rejoin_live_gap(bool panic_floor) {
        with_active_muc((stream_interactor, account, conversation) => {
            Database database = get_muc_audit_database();
            stream_interactor.add_module(new ContentItemStore.for_tests(
                stream_interactor, database));
            HistorySync history = stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY).history_sync;
            history.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream(stream_interactor,
                account, conversation.counterpart, conversation.nickname);
            var loop = new MainLoop();
            string? failure = null;
            run_rejoin_live_gap.begin(stream_interactor, history, account,
                conversation, stream, panic_floor, (obj, response) => {
                    try { run_rejoin_live_gap.end(response); }
                    catch (Error error) { failure = error.message; }
                    loop.quit();
                });
            uint timeout = Timeout.add_seconds(5, () => {
                failure = "same-stream MAM rejoin audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_rejoin_live_gap(StreamInteractor stream_interactor,
            HistorySync history, Account account, Conversation conversation,
            MucManagerAuditStream stream, bool panic_floor) throws Error {
        Database database = get_muc_audit_database();
        MucManager manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);
        MessageProcessor processor = stream_interactor.get_module<
            MessageProcessor>(MessageProcessor.IDENTITY);
        conversation.encryption = Encryption.NONE;
        validate_join_result(yield manager.join(account,
            conversation.counterpart, conversation.nickname, null, false),
            "initial history audit join");
        long now = (long) (new DateTime.now_utc()).to_unix();
        if (panic_floor) history.set_panic_sync_floor(
            new DateTime.from_unix_utc(now - 2 * 86400));
        int old_range = insert_history_audit_range(database, account,
            conversation.counterpart, "old", now - 10 * 86400,
            now - 7 * 86400);
        history.current_catchup_id[account][conversation.counterpart] = old_range;
        var sibling_room = new Jid("sibling@conference.example.test");
        int sibling_range = insert_history_audit_range(database, account,
            sibling_room, "sibling", now - 10 * 86400, now - 7 * 86400);
        history.current_catchup_id[account][sibling_room] = sibling_range;

        manager.part(account, conversation.counterpart);
        stream.disco_mam = true;
        stream.defer_disco_info = true;
        validate_join_result(yield manager.join(account,
            conversation.counterpart, conversation.nickname, null, false),
            "same-stream history audit rejoin");
        if (stream.join_presence_count != 2 || stream.mam_iq_count != 0) {
            throw new IOError.FAILED(
                "same-stream rejoin did not hold room discovery before MAM");
        }

        bool live_admitted = false;
        ulong received_handler = processor.message_received.connect(
            (message, delivered_conversation) => {
                if (message.account == account &&
                        delivered_conversation == conversation &&
                        message.body == "ordinary new live message") {
                    live_admitted = true;
                }
            });
        try {
            var live = new StanzaNode.build("message", "jabber:client")
                .add_self_xmlns()
                .put_attribute("from", conversation.counterpart.to_string() + "/bob")
                .put_attribute("to", account.full_jid.to_string())
                .put_attribute("type", Xmpp.MessageStanza.TYPE_GROUPCHAT)
                .put_attribute("id", "current-live")
                .put_node(new StanzaNode.build("body", "jabber:client")
                    .put_node(new StanzaNode.text("ordinary new live message")))
                .put_node(new StanzaNode.build("stanza-id",
                        Xmpp.Xep.UniqueStableStanzaIDs.NS_URI)
                    .add_self_xmlns()
                    .put_attribute("by", conversation.counterpart.to_string())
                    .put_attribute("id", "current-live-archive"));
            stream.received_message_stanza(stream, live);
            int ticks = 0;
            while (!live_admitted && ticks++ < 200) {
                yield wait_muc_audit_low_tick();
            }
            if (!live_admitted) throw new IOError.FAILED(
                "rejoin audit did not admit the actual new live message");
            Qlite.Row old = database.mam_catchup.select()
                .with<int>(database.mam_catchup.id, "=", old_range)
                .single().row().inner;
            if ((string) old[database.mam_catchup.to_id] != "old-last" ||
                    (long) old[database.mam_catchup.to_time] != now - 7 * 86400) {
                throw new IOError.FAILED(
                    "the new live arrival bridged unseen offline time in an old persisted range");
            }
            if (!history.current_catchup_id[account].has_key(sibling_room) ||
                    history.current_catchup_id[account][sibling_room] !=
                        sibling_range) throw new IOError.FAILED(
                "leaving/rejoining one room invalidated a sibling room's live cursor");

            stream.release_held_disco_successes();
            yield wait_for_history_audit_request(stream, 1);
            DateTime? first_start = history_audit_request_start(stream, 0);
            long expected_floor = now - (panic_floor ? 2 : 5) * 86400;
            // Rejoin computes its window a few main-context turns after now.
            if (first_start == null || ((!) first_start).to_unix() <
                    expected_floor || ((!) first_start).to_unix() >
                    expected_floor + 5) throw new IOError.FAILED(
                "rejoin latest query skipped the offline window or crossed the panic floor");
            stream.emit_mam_archived_message(0, "current-live-archive",
                Xmpp.Xep.DateTimeProfiles.to_datetime(
                    new DateTime.from_unix_utc(now)));
            // More older results exist: this avoids pretending a complete
            // date-filtered response proves unseen messages within its filter.
            stream.emit_mam_fin(0, false, "current-live-archive");
            yield wait_for_history_audit_request(stream, 2);
            DateTime? backward_start = history_audit_request_start(stream, 1);
            if (backward_start == null || ((!) backward_start).to_unix() <
                    expected_floor || ((!) backward_start).to_unix() >
                    expected_floor + 5) throw new IOError.FAILED(
                "rejoin backward page used the wrong offline/privacy window");
            stream.emit_mam_archived_message(1, "offline-gap-message",
                Xmpp.Xep.DateTimeProfiles.to_datetime(
                    new DateTime.from_unix_utc(now - 86400)),
                "message received while the room was left");
            stream.emit_mam_fin(1, true, "offline-gap-message");
            ticks = 0;
            while (manager.has_pending_muc_mam_sync_for_tests(account,
                    conversation.counterpart) && ticks++ < 200) {
                yield wait_muc_audit_low_tick();
            }
            if (manager.has_pending_muc_mam_sync_for_tests(account,
                    conversation.counterpart) ||
                    manager.has_muc_mam_retry_scheduled_for_tests(account,
                        conversation.counterpart) || stream.mam_iq_count != 2) {
                throw new IOError.FAILED(
                    "the real rejoin backfill did not finish without retries");
            }
            old = database.mam_catchup.select()
                .with<int>(database.mam_catchup.id, "=", old_range)
                .single().row().inner;
            if ((string) old[database.mam_catchup.to_id] != "old-last") {
                throw new IOError.FAILED(
                    "rejoin catch-up rewrote coverage outside its requested window");
            }
        } finally {
            processor.disconnect(received_handler);
        }
    }

    private void test_v54_mam_coverage_migration() {
        string temp_dir = "";
        string db_path = "";
        const string key = "mam-coverage-migration-test";
        Database? database = null;
        StreamInteractor? stream_interactor = null;
        MucManagerTestApplication? application = null;
        Account? active_account = null;
        GLib.Application? previous_application = GLib.Application.get_default();
        try {
            temp_dir = DirUtils.make_tmp("dinox-mam-v54-XXXXXX");
            db_path = Path.build_filename(temp_dir, "dino.db");
            database = new Database(db_path, key);
            var account = new Account(new Jid("alice@example.test"), "secret") {
                enabled = true
            };
            var other_account = new Account(new Jid("other@example.test"), "secret");
            account.persist((!) database);
            other_account.persist((!) database);
            int account_id = account.id;
            int other_account_id = other_account.id;
            var room = new Jid("room@conference.example.test");
            var conversation = new Conversation(room, account,
                Conversation.Type.GROUPCHAT) { nickname = "alice", active = true };
            long now = (long) (new DateTime.now_utc()).to_unix();
            conversation.history_cleared_at = new DateTime.from_unix_utc(
                now - 20 * 86400);
            conversation.persist((!) database);
            int conversation_id = conversation.id;
            var message = new Message("retained local history") {
                account = account,
                counterpart = room.with_resource("archivist"),
                ourpart = account.full_jid,
                direction = Message.DIRECTION_RECEIVED,
                type_ = Message.Type.GROUPCHAT,
                time = new DateTime.from_unix_utc(now - 86400),
                local_time = new DateTime.from_unix_utc(now - 86400),
                encryption = Encryption.OMEMO,
                marked = Message.Marked.READ,
                stanza_id = "retained-message"
            };
            message.persist((!) database);
            int message_id = message.id;
            string file_key = ((!) database).get_or_create_file_encryption_key(
                "retained-file-encryption-key");
            ((!) database).exec_prepared(
                "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                { "history-migration-setting", "retained-setting" });
            // Old metadata cannot distinguish a false beginning marker from
            // a false assertion that one range covers an offline gap.
            insert_history_audit_range((!) database, account, room,
                "poisoned", now - 30 * 86400, now, true);
            insert_history_audit_range((!) database, account,
                new Jid("sibling@conference.example.test"), "wrong-covered",
                now - 30 * 86400, now, false);
            insert_history_audit_range((!) database, other_account, room,
                "other-account", now - 30 * 86400, now, true);
            downgrade_history_audit_conversation_schema((!) database, 54);
            downgrade_history_audit_message_schema((!) database, 54);
            rebuild_account_fixture_at_version((!) database, 54);
            ((!) database).exec(
                "UPDATE _meta SET int_val = 54 WHERE name = 'version'");
            ((!) database).close();
            database = null;

            database = new Database(db_path, key);
            if (((!) database).mam_catchup.select().count() != 0) {
                throw new IOError.FAILED(
                    "v54 migration retained untrustworthy poisoned/wrong-covered MAM metadata");
            }
            Account? loaded_account = ((!) database).get_account_by_id(account_id);
            if (loaded_account == null ||
                    ((!) database).get_account_by_id(other_account_id) == null ||
                    ((!) loaded_account).bare_jid.to_string() != "alice@example.test") {
                throw new IOError.FAILED(
                    "MAM metadata migration changed account identities");
            }
            Qlite.Row retained_message = ((!) database).message.select()
                .with<int>(((!) database).message.id, "=", message_id)
                .single().row().inner;
            Qlite.Row retained_conversation = ((!) database).conversation.select()
                .with<int>(((!) database).conversation.id, "=", conversation_id)
                .single().row().inner;
            string[] retained_setting = ((!) database).query_column_checked(
                "SELECT value FROM settings WHERE key = ?",
                { "history-migration-setting" });
            if ((string) retained_message[((!) database).message.body] !=
                        "retained local history" ||
                    (int) retained_message[((!) database).message.mention_state] !=
                        (int) Message.MentionState.UNKNOWN ||
                    (int) retained_message[((!) database).message.encryption] !=
                        (int) Encryption.OMEMO ||
                    (long) retained_conversation[
                        ((!) database).conversation.history_cleared_at] !=
                            now - 20 * 86400 ||
                    retained_setting.length != 1 ||
                    retained_setting[0] != "retained-setting" ||
                    ((!) database).get_or_create_file_encryption_key(
                        "must-not-replace-file-key") != file_key) {
                throw new IOError.FAILED(
                    "MAM migration changed local messages, encryption key, settings or clear-history policy");
            }

            stream_interactor = new StreamInteractor.for_tests((!) database);
            application = new MucManagerTestApplication((!) database,
                (!) stream_interactor);
            GLib.Application.set_default((!) application);
            start_muc_test_modules((!) stream_interactor, (!) database);
            active_account = (!) loaded_account;
            ((!) stream_interactor).module_manager.initialize((!) active_account);
            ((!) stream_interactor).account_added((!) active_account);
            ConversationManager conversations = ((!) stream_interactor).get_module<
                ConversationManager>(ConversationManager.IDENTITY);
            Conversation current = conversations.create_conversation(room,
                (!) active_account, Conversation.Type.GROUPCHAT);
            current.nickname = "alice";
            conversations.start_conversation(current);
            if (current.id != conversation_id) throw new IOError.FAILED(
                "migration backfill did not reuse the retained conversation");
            HistorySync history = ((!) stream_interactor).get_module<
                MessageProcessor>(MessageProcessor.IDENTITY).history_sync;
            history.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream((!) stream_interactor,
                (!) active_account, room, current.nickname);
            var loop = new MainLoop();
            string? failure = null;
            complete_bounded_backfill.begin(history, (!) active_account, room,
                stream, 0, now, 7, (obj, response) => {
                    try { complete_bounded_backfill.end(response); }
                    catch (Error error) { failure = error.message; }
                    loop.quit();
                });
            uint timeout = Timeout.add_seconds(5, () => {
                failure = "migrated MAM backfill audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout);
            if (failure != null) throw new IOError.FAILED((!) failure);
            Qlite.Row rebuilt = get_history_audit_range((!) database,
                (!) active_account, room);
            int rebuilt_id = rebuilt[((!) database).mam_catchup.id];
            ((!) stream_interactor).connection_manager.disconnect_all();
            ((!) stream_interactor).account_removed((!) active_account);
            ((!) stream_interactor).get_module<MucManager>(
                MucManager.IDENTITY).shutdown();
            stream_interactor = null;
            active_account = null;
            GLib.Application.set_default(previous_application);
            application = null;
            ((!) database).close();
            database = null;

            database = new Database(db_path, key);
            Qlite.RowOption reopened = ((!) database).mam_catchup.select()
                .with<int>(((!) database).mam_catchup.id, "=", rebuilt_id)
                .single().row();
            if (!reopened.is_present() ||
                    (bool) reopened.inner[((!) database).mam_catchup.from_end] ||
                    (long) reopened.inner[((!) database).mam_catchup.from_time] !=
                        now - 7 * 86400 ||
                    ((!) database).message.select().with<int>(
                        ((!) database).message.id, "=", message_id).count() != 1) {
                throw new IOError.FAILED(
                    "reopening v55 repeated metadata invalidation or lost retained history");
            }
        } catch (Error error) {
            fail_if_reached("Unexpected MAM migration audit error: " + error.message);
        } finally {
            if (stream_interactor != null) {
                ((!) stream_interactor).connection_manager.disconnect_all();
                if (active_account != null) {
                    ((!) stream_interactor).account_removed((!) active_account);
                }
                MucManager? manager = ((!) stream_interactor).get_module<
                    MucManager>(MucManager.IDENTITY);
                if (manager != null) ((!) manager).shutdown();
            }
            if (application != null &&
                    GLib.Application.get_default() == (!) application) {
                GLib.Application.set_default(previous_application);
            }
            while (MainContext.default().pending()) {
                MainContext.default().iteration(false);
            }
            if (database != null) ((!) database).close();
            if (temp_dir != "") cleanup_muc_test_dir(temp_dir, db_path);
        }
    }

    private static Xmpp.MessageStanza build_history_policy_ciphertext(
            Account account, Jid room, bool archived,
            DateTime? archive_time) throws Error {
        string id = "history-policy-" + Uuid.string_random();
        const string omemo_namespace = "eu.siacs.conversations.axolotl";
        var node = new StanzaNode.build("message", "jabber:client")
            .add_self_xmlns()
            .put_attribute("from", room.to_string() + "/archivist")
            .put_attribute("to", account.full_jid.to_string())
            .put_attribute("type", Xmpp.MessageStanza.TYPE_GROUPCHAT)
            .put_attribute("id", id)
            .put_node(new StanzaNode.build("body", "jabber:client")
                .put_node(new StanzaNode.text("encrypted archive fallback")))
            .put_node(new StanzaNode.build("encrypted", omemo_namespace)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("header", omemo_namespace)
                    .put_attribute("sid", "100")
                    .put_node(new StanzaNode.build("key", omemo_namespace)
                        .put_attribute("rid", "200")
                        .put_node(new StanzaNode.text("Y2lwaGVydGV4dA==")))
                    .put_node(new StanzaNode.build("iv", omemo_namespace)
                        .put_node(new StanzaNode.text("AAAAAAAAAAAAAAAAAAAAAA=="))))
                .put_node(new StanzaNode.build("payload", omemo_namespace)
                    .put_node(new StanzaNode.text("Y2lwaGVydGV4dA=="))));
        var stanza = new Xmpp.MessageStanza.from_stanza(node, account.full_jid);
        if (archived) {
            // The transport/query tests above exercise real MAM responses.
            // Here the validated archive flag is fed into the actual message
            // pipeline to prove policy admission happens before DECRYPT.
            stanza.add_flag(new Xmpp.MessageArchiveManagement.MessageFlag(
                room, archive_time, id, "history-policy-query"));
        }
        return stanza;
    }

    private void test_mam_privacy_before_decrypt(bool expiry, bool missing_time) {
        with_active_muc((stream_interactor, account, conversation) => {
            MessageProcessor processor = stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY);
            processor.history_sync.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream(stream_interactor,
                account, conversation.counterpart, conversation.nickname);
            var decrypt = new CountingHistoryPolicyDecryptListener();
            processor.received_pipeline.connect(decrypt);
            DateTime now = new DateTime.now_utc();
            if (expiry) conversation.message_expiry_seconds = 3600;
            else conversation.history_cleared_at = now.add_hours(-1);
            DateTime? archived_time = missing_time ? null : now.add_hours(-2);
            var stanza = build_history_policy_ciphertext(account,
                conversation.counterpart, true, archived_time);
            var loop = new MainLoop();
            processor.run_pipeline_announce_on_stream.begin(account, stream,
                stanza, null, (obj, response) => {
                    processor.run_pipeline_announce_on_stream.end(response);
                    loop.quit();
                });
            uint timeout = Timeout.add_seconds(5, () => {
                fail_if_reached("MAM privacy pipeline audit timed out");
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout);
            processor.received_pipeline.disconnect(decrypt);
            if (decrypt.calls != 0) throw new IOError.FAILED(
                "cleared/expired or timestamp-less archived ciphertext reached DECRYPT");
        });
    }

    private void test_mam_privacy_scope_and_live() {
        with_active_muc((stream_interactor, account, conversation) => {
            Database database = get_muc_audit_database();
            MessageProcessor processor = stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY);
            processor.history_sync.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream(stream_interactor,
                account, conversation.counterpart, conversation.nickname);
            var decrypt = new CountingHistoryPolicyDecryptListener();
            processor.received_pipeline.connect(decrypt);
            var other_account = new Account(new Jid("other@example.test"), "secret") {
                enabled = true
            };
            other_account.persist(database);
            stream_interactor.module_manager.initialize(other_account);
            stream_interactor.account_added(other_account);
            try {
                var other_stream = prepare_history_audit_stream(stream_interactor,
                    other_account, conversation.counterpart, "other");
                ConversationManager conversations = stream_interactor.get_module<
                    ConversationManager>(ConversationManager.IDENTITY);
                var sibling_room = new Jid("sibling@conference.example.test");
                Conversation sibling = conversations.create_conversation(
                    sibling_room, account, Conversation.Type.GROUPCHAT);
                conversations.start_conversation(sibling);
                Conversation same_room_other_account = conversations.create_conversation(
                    conversation.counterpart, other_account,
                    Conversation.Type.GROUPCHAT);
                conversations.start_conversation(same_room_other_account);
                DateTime now = new DateTime.now_utc();
                conversation.history_cleared_at = now.add_hours(-1);
                conversation.message_expiry_seconds = 3600;
                var loop = new MainLoop();
                string? failure = null;
                run_mam_privacy_scope_and_live.begin(processor, decrypt,
                    account, conversation, stream, other_account,
                    same_room_other_account, other_stream, sibling, now,
                    (obj, response) => {
                        try { run_mam_privacy_scope_and_live.end(response); }
                        catch (Error error) { failure = error.message; }
                        loop.quit();
                    });
                uint timeout = Timeout.add_seconds(5, () => {
                    failure = "MAM scoped policy pipeline audit timed out";
                    loop.quit();
                    return Source.REMOVE;
                });
                loop.run();
                Source.remove(timeout);
                if (failure != null) throw new IOError.FAILED((!) failure);
            } finally {
                processor.received_pipeline.disconnect(decrypt);
                stream_interactor.account_removed(other_account);
            }
        });
    }

    private async void assert_history_policy_decrypt_admitted(
            MessageProcessor processor, CountingHistoryPolicyDecryptListener decrypt,
            Account account, Conversation conversation,
            MucManagerAuditStream stream, bool archived,
            DateTime? timestamp) throws Error {
        int previous_calls = decrypt.calls;
        var stanza = build_history_policy_ciphertext(account,
            conversation.counterpart, archived, timestamp);
        yield processor.run_pipeline_announce_on_stream(account, stream, stanza);
        if (decrypt.calls != previous_calls + 1 ||
                decrypt.last_account_id != account.id ||
                decrypt.last_conversation_id != conversation.id) {
            throw new IOError.FAILED(
                "fresh/live or unrelated room/account ciphertext was blocked or retargeted by another history policy");
        }
    }

    private async void run_mam_privacy_scope_and_live(MessageProcessor processor,
            CountingHistoryPolicyDecryptListener decrypt, Account account,
            Conversation conversation, MucManagerAuditStream stream,
            Account other_account, Conversation other_conversation,
            MucManagerAuditStream other_stream, Conversation sibling,
            DateTime now) throws Error {
        yield assert_history_policy_decrypt_admitted(processor, decrypt,
            account, conversation, stream, true, now.add_seconds(-5));
        yield assert_history_policy_decrypt_admitted(processor, decrypt,
            account, conversation, stream, false, null);
        yield assert_history_policy_decrypt_admitted(processor, decrypt,
            account, sibling, stream, true, now.add_days(-7));
        yield assert_history_policy_decrypt_admitted(processor, decrypt,
            other_account, other_conversation, other_stream, true,
            now.add_days(-7));
        // A missing archive timestamp is fail-closed only when that exact
        // conversation has a deletion/expiry rule, not as a global MAM ban.
        yield assert_history_policy_decrypt_admitted(processor, decrypt,
            account, sibling, stream, true, null);
    }

    private void test_mam_policy_change_while_held(bool expiry) {
        with_active_muc((stream_interactor, account, conversation) => {
            MessageProcessor processor = stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY);
            processor.history_sync.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream(stream_interactor,
                account, conversation.counterpart, conversation.nickname);
            var hold = new HistoryPolicyHoldListener();
            var decrypt = new CountingHistoryPolicyDecryptListener(true);
            processor.received_pipeline.connect(hold);
            processor.received_pipeline.connect(decrypt);
            try {
                var loop = new MainLoop();
                string? failure = null;
                run_mam_policy_change_while_held.begin(processor, hold,
                    decrypt, account, conversation, stream, expiry,
                    (obj, response) => {
                        try { run_mam_policy_change_while_held.end(response); }
                        catch (Error error) { failure = error.message; }
                        loop.quit();
                    });
                uint timeout = Timeout.add_seconds(5, () => {
                    failure = "held MAM privacy listener audit timed out";
                    loop.quit();
                    return Source.REMOVE;
                });
                loop.run();
                Source.remove(timeout);
                if (failure != null) throw new IOError.FAILED((!) failure);
            } finally {
                hold.release();
                processor.received_pipeline.disconnect(hold);
                processor.received_pipeline.disconnect(decrypt);
            }
        });
    }

    private async void run_mam_policy_change_while_held(
            MessageProcessor processor, HistoryPolicyHoldListener hold,
            CountingHistoryPolicyDecryptListener decrypt, Account account,
            Conversation conversation, MucManagerAuditStream stream,
            bool expiry) throws Error {
        var stanza = build_history_policy_ciphertext(account,
            conversation.counterpart, true,
            new DateTime.now_utc().add_minutes(-10));
        bool done = false;
        processor.run_pipeline_announce_on_stream.begin(account, stream,
            stanza, null, (obj, response) => {
                processor.run_pipeline_announce_on_stream.end(response);
                done = true;
            });
        int ticks = 0;
        while (!hold.entered && !done && ticks++ < 200) {
            yield wait_muc_audit_low_tick();
        }
        if (!hold.entered || done || decrypt.calls != 0) {
            throw new IOError.FAILED(
                "the actual message pipeline was not held before DECRYPT");
        }
        if (expiry) conversation.message_expiry_seconds = 60;
        else conversation.history_cleared_at = new DateTime.now_utc();
        hold.release();
        ticks = 0;
        while (!done && ticks++ < 200) yield wait_muc_audit_low_tick();
        if (!done || decrypt.calls != 0) throw new IOError.FAILED(
            "a history policy changed during a held listener but ciphertext still reached DECRYPT");
    }

    private void test_mam_cancelled_before_start() {
        with_active_muc((stream_interactor, account, conversation) => {
            Database database = get_muc_audit_database();
            HistorySync history = stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY).history_sync;
            history.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream(stream_interactor,
                account, conversation.counterpart, conversation.nickname);
            long now = (long) (new DateTime.now_utc()).to_unix();
            int existing = insert_history_audit_range(database, account,
                conversation.counterpart, "existing", now - 86400, now);
            var sibling = new Jid("sibling@conference.example.test");
            int sibling_range = insert_history_audit_range(database, account,
                sibling, "sibling", now - 86400, now);
            history.current_catchup_id[account][conversation.counterpart] = existing;
            history.current_catchup_id[account][sibling] = sibling_range;
            var cancelled = new Cancellable();
            cancelled.cancel();
            bool done = false;
            HistorySync.FetchResult result = HistorySync.FetchResult.SUCCESS;
            var loop = new MainLoop();
            history.fetch_everything.begin(account, conversation.counterpart,
                new HistorySync.FetchCancellation(cancelled),
                new DateTime.from_unix_utc(now - 5 * 86400), (obj, response) => {
                    result = history.fetch_everything.end(response);
                    done = true;
                    loop.quit();
                });
            uint timeout = Timeout.add_seconds(5, () => {
                fail_if_reached("pre-cancelled MAM audit timed out");
                loop.quit();
                return Source.REMOVE;
            });
            if (!done) loop.run();
            Source.remove(timeout);
            if (!done || result != HistorySync.FetchResult.CANCELLED ||
                    stream.mam_iq_count != 0 ||
                    !history.current_catchup_id[account].has_key(
                        conversation.counterpart) ||
                    history.current_catchup_id[account][conversation.counterpart] !=
                        existing || !history.current_catchup_id[account].has_key(sibling) ||
                    history.current_catchup_id[account][sibling] != sibling_range ||
                    (string) get_history_audit_range(database, account,
                        conversation.counterpart)[database.mam_catchup.to_id] !=
                            "existing-last") {
                throw new IOError.FAILED(
                    "an already-cancelled fetch changed live cursor/coverage or issued a MAM query");
            }
        });
    }

    private void test_stale_account_mam_completion_preserves_new_owner() {
        with_active_muc((stream_interactor, account, conversation) => {
            MessageProcessor? processor = stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY);
            if (processor == null) throw new IOError.FAILED(
                "owner-fence audit setup is missing MessageProcessor");
            HistorySync history_sync = ((!) processor).history_sync;
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            attach_account_module_for_tests<
                Xmpp.MessageArchiveManagement.Module>(stream_interactor,
                    account, stream,
                    Xmpp.MessageArchiveManagement.Module.IDENTITY);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            Xmpp.MessageArchiveManagement.Module? mam_module =
                stream_interactor.module_manager.get_module<
                    Xmpp.MessageArchiveManagement.Module>(account,
                        Xmpp.MessageArchiveManagement.Module.IDENTITY);
            if (mam_module == null) throw new IOError.FAILED(
                "owner-fence audit setup is missing the MAM module");

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_stale_account_mam_owner_audit.begin(history_sync, account,
                stream, (!) mam_module, (obj, res) => {
                    try {
                        run_stale_account_mam_owner_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(5, () => {
                timeout_id = 0;
                failure = "timed out waiting for account-MAM owner fence audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_stale_account_mam_owner_audit(
            HistorySync history_sync, Account account,
            MucManagerAuditStream stream,
            Xmpp.MessageArchiveManagement.Module mam_module) throws Error {
        history_sync.auto_fetch_enabled = true;
        mam_module.feature_available(stream);
        yield wait_muc_audit_delay(100);
        int ticks = 0;
        while (stream.mam_iq_count < 1 && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.mam_iq_count < 1 ||
                !history_sync.cancellables.has_key(account) ||
                !history_sync.cancellables[account].has_key(
                    account.bare_jid)) {
            throw new IOError.FAILED(
                "first account-MAM owner did not start (iqs=%d account-map=%s owner=%s)".printf(
                    stream.mam_iq_count,
                    history_sync.cancellables.has_key(account).to_string(),
                    (history_sync.cancellables.has_key(account) &&
                        history_sync.cancellables[account].has_key(
                            account.bare_jid)).to_string()));
        }
        Cancellable owner_a =
            history_sync.cancellables[account][account.bare_jid];

        // Allow a new account-wide intent on the same synthetic stream.  The
        // productive path reaches this through a replacement stream.
        history_sync.sync_streams.unset(account);
        mam_module.feature_available(stream);
        yield wait_muc_audit_delay(100);
        ticks = 0;
        while (stream.mam_iq_count < 2 && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.mam_iq_count != 2 || !owner_a.is_cancelled() ||
                !history_sync.cancellables.has_key(account) ||
                !history_sync.cancellables[account].has_key(
                    account.bare_jid)) {
            throw new IOError.FAILED(
                "replacement account-MAM owner did not supersede owner A");
        }
        Cancellable owner_b =
            history_sync.cancellables[account][account.bare_jid];
        if (owner_b == owner_a || owner_b.is_cancelled()) {
            throw new IOError.FAILED(
                "replacement account-MAM owner must be live and distinct");
        }

        DateTime owner_b_time = new DateTime.from_unix_utc(1800000000);
        history_sync.mam_times[account]["owner-b-sentinel"] = owner_b_time;
        for (int i = 0; i < 20; i++) yield wait_muc_audit_low_tick();
        if (!history_sync.cancellables.has_key(account) ||
                !history_sync.cancellables[account].has_key(
                    account.bare_jid) ||
                history_sync.cancellables[account][account.bare_jid] !=
                    owner_b ||
                !history_sync.mam_times[account].has_key(
                    "owner-b-sentinel")) {
            throw new IOError.FAILED(
                "stale owner A completion removed owner B or its MAM timestamp");
        }

        stream.emit_mam_success(1);
        ticks = 0;
        while ((history_sync.cancellables.has_key(account) ||
                !Xmpp.MessageArchiveManagement.Flag.get_flag(stream)
                    .active_query_ids.is_empty) && ticks++ < 200) {
            yield wait_muc_audit_low_tick();
        }
        if (history_sync.cancellables.has_key(account) ||
                !history_sync.mam_times[account].is_empty) {
            throw new IOError.FAILED(
                "current owner B completion did not release owner and timestamps");
        }
    }

    private void test_parallel_account_and_muc_mam_timestamps_are_query_scoped() {
        with_active_muc((stream_interactor, account, conversation) => {
            MessageProcessor? processor = stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY);
            if (processor == null) throw new IOError.FAILED(
                "parallel MAM audit setup is missing MessageProcessor");
            HistorySync history_sync = ((!) processor).history_sync;
            history_sync.auto_fetch_enabled = false;
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            attach_account_module_for_tests<
                Xmpp.MessageArchiveManagement.Module>(stream_interactor,
                    account, stream,
                    Xmpp.MessageArchiveManagement.Module.IDENTITY);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_parallel_mam_timestamp_audit.begin(history_sync, account,
                conversation.counterpart, stream, (obj, res) => {
                    try {
                        run_parallel_mam_timestamp_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(5, () => {
                timeout_id = 0;
                failure = "timed out waiting for parallel MAM timestamp audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_parallel_mam_timestamp_audit(
            HistorySync history_sync, Account account, Jid room,
            MucManagerAuditStream stream) throws Error {
        bool account_done = false;
        bool room_done = false;
        HistorySync.FetchResult account_result = HistorySync.FetchResult.ERROR;
        HistorySync.FetchResult room_result = HistorySync.FetchResult.ERROR;
        history_sync.fetch_latest_page.begin(account, account.bare_jid, null,
            history_sync.sync_not_before, null, (obj, res) => {
                history_sync.fetch_latest_page.end(res, out account_result);
                account_done = true;
            });
        history_sync.fetch_latest_page.begin(account, room.bare_jid, null,
            history_sync.sync_not_before, null, (obj, res) => {
                history_sync.fetch_latest_page.end(res, out room_result);
                room_done = true;
            });

        int ticks = 0;
        while (stream.mam_iq_count < 2 && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.mam_iq_count != 2) {
            throw new IOError.FAILED(
                "parallel account and MUC fetches did not both start");
        }

        const string SHARED_ARCHIVE_ID = "shared-archive-id";
        const string ACCOUNT_STAMP = "2027-01-15T10:00:00Z";
        const string MUC_STAMP = "2027-01-15T11:00:00Z";
        stream.emit_mam_archived_message(0, SHARED_ARCHIVE_ID,
            ACCOUNT_STAMP);
        stream.emit_mam_archived_message(1, SHARED_ARCHIVE_ID, MUC_STAMP);
        ticks = 0;
        while (history_sync.mam_times[account].size < 2 && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (history_sync.mam_times[account].size != 2) {
            throw new IOError.FAILED(
                "colliding archive IDs were not retained per MAM query");
        }

        stream.emit_mam_fin(0, false, SHARED_ARCHIVE_ID);
        ticks = 0;
        while (!account_done && ticks++ < 200) {
            yield wait_muc_audit_low_tick();
        }
        if (!account_done || room_done ||
                account_result != HistorySync.FetchResult.SUCCESS ||
                history_sync.mam_times[account].size != 2) {
            throw new IOError.FAILED(
                "account fetch completion cleared the still-active MUC timestamps");
        }

        stream.emit_mam_fin(1, false, SHARED_ARCHIVE_ID);
        ticks = 0;
        while (!room_done && ticks++ < 200) {
            yield wait_muc_audit_low_tick();
        }
        DateTime? account_time = new DateTime.from_iso8601(ACCOUNT_STAMP,
            null);
        DateTime? muc_time = new DateTime.from_iso8601(MUC_STAMP, null);
        if (!room_done || room_result != HistorySync.FetchResult.SUCCESS ||
                account_time == null || muc_time == null ||
                get_mam_range_from_time_for_tests(account,
                    account.bare_jid) != ((!) account_time).to_unix() ||
                get_mam_range_from_time_for_tests(account, room) !=
                    ((!) muc_time).to_unix() ||
                !history_sync.mam_times[account].is_empty) {
            throw new IOError.FAILED(
                "parallel query-scoped timestamps did not reach their own DB ranges and final cleanup");
        }
    }

    private void test_mam_readiness_gate_blocks_query_and_range_commit() {
        with_active_muc((stream_interactor, account, conversation) => {
            MessageProcessor? processor = stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY);
            if (processor == null) throw new IOError.FAILED(
                "readiness-gate audit setup is missing MessageProcessor");
            HistorySync history_sync = ((!) processor).history_sync;
            history_sync.auto_fetch_enabled = false;
            var gate = new TestHistorySyncReadinessGate(false);
            history_sync.add_readiness_gate(gate);

            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            attach_account_module_for_tests<
                Xmpp.MessageArchiveManagement.Module>(stream_interactor,
                    account, stream,
                    Xmpp.MessageArchiveManagement.Module.IDENTITY);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_mam_readiness_gate_blocks_query.begin(history_sync, account,
                conversation.counterpart, stream, (obj, res) => {
                    try {
                        run_mam_readiness_gate_blocks_query.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(5, () => {
                timeout_id = 0;
                failure = "timed out waiting for MAM readiness-gate audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_mam_readiness_gate_blocks_query(
            HistorySync history_sync, Account account, Jid room,
            MucManagerAuditStream stream) throws Error {
        HistorySync.FetchResult fetch_result;
        Qlite.Row? row = yield history_sync.fetch_latest_page(account,
            room.bare_jid, null, history_sync.sync_not_before, null,
            out fetch_result);
        if (row != null || fetch_result != HistorySync.FetchResult.ERROR ||
                stream.mam_iq_count != 0 ||
                get_mam_range_count_for_tests(account, room) != 0) {
            throw new IOError.FAILED(
                "an unready product store must prevent the MAM IQ and every range commit");
        }
    }

    private void test_mam_readiness_loss_during_page_preserves_cursor() {
        with_active_muc((stream_interactor, account, conversation) => {
            MessageProcessor? processor = stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY);
            if (processor == null) throw new IOError.FAILED(
                "readiness-loss audit setup is missing MessageProcessor");
            HistorySync history_sync = ((!) processor).history_sync;
            history_sync.auto_fetch_enabled = false;
            var gate = new TestHistorySyncReadinessGate(true);
            history_sync.add_readiness_gate(gate);
            ((!) processor).received_pipeline.connect(
                new FlipReadinessOnDecryptListener(gate, account));

            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            attach_account_module_for_tests<
                Xmpp.MessageArchiveManagement.Module>(stream_interactor,
                    account, stream,
                    Xmpp.MessageArchiveManagement.Module.IDENTITY);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            seed_mam_range_for_tests(account, conversation.counterpart,
                false);
            Database audit_db = get_muc_audit_database();
            Qlite.RowOption latest_row_opt = audit_db.mam_catchup.select()
                .with<int>(audit_db.mam_catchup.account_id, "=", account.id)
                .with<string>(audit_db.mam_catchup.server_jid, "=",
                    conversation.counterpart.bare_jid.to_string())
                .single().row();
            if (!latest_row_opt.is_present()) throw new IOError.FAILED(
                "readiness-loss audit did not seed its existing cursor");
            Qlite.Row latest_row = (!) latest_row_opt.inner;
            string expected_to_id = latest_row[audit_db.mam_catchup.to_id];
            long expected_to_time = latest_row[audit_db.mam_catchup.to_time];

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_mam_readiness_loss_during_page.begin(history_sync, account,
                conversation.counterpart, stream, gate, latest_row,
                expected_to_id, expected_to_time, (obj, res) => {
                    try {
                        run_mam_readiness_loss_during_page.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(5, () => {
                timeout_id = 0;
                failure = "timed out waiting for MAM readiness-loss audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_mam_readiness_loss_during_page(
            HistorySync history_sync, Account account, Jid room,
            MucManagerAuditStream stream,
            TestHistorySyncReadinessGate gate, Qlite.Row latest_row,
            string expected_to_id, long expected_to_time) throws Error {
        bool done = false;
        Qlite.Row? result_row = null;
        HistorySync.FetchResult fetch_result = HistorySync.FetchResult.SUCCESS;
        history_sync.fetch_latest_page.begin(account, room.bare_jid,
            latest_row,
            history_sync.sync_not_before, null, (obj, res) => {
                result_row = history_sync.fetch_latest_page.end(res,
                    out fetch_result);
                done = true;
            });

        int ticks = 0;
        while (stream.mam_iq_count < 1 && ticks++ < 100) {
            yield wait_muc_audit_low_tick();
        }
        if (stream.mam_iq_count != 1) {
            throw new IOError.FAILED(
                "the ready gate did not allow the held MAM page to start");
        }

        const string ARCHIVE_ID = "readiness-loss-archive-id";
        GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
            "*refusing to persist a partially processed archive message*");
        stream.emit_mam_archived_message(0, ARCHIVE_ID,
            "2026-08-03T06:00:00Z", "must-not-be-persisted");
        stream.emit_mam_fin(0, true, ARCHIVE_ID);
        ticks = 0;
        while (!done && ticks++ < 200) {
            yield wait_muc_audit_low_tick();
        }
        GLib.Test.assert_expected_messages();
        Database audit_db = get_muc_audit_database();
        Qlite.RowOption persisted_row_opt = audit_db.mam_catchup.select()
            .with<int>(audit_db.mam_catchup.account_id, "=", account.id)
            .with<string>(audit_db.mam_catchup.server_jid, "=",
                room.bare_jid.to_string())
            .single().row();
        bool cursor_preserved = false;
        if (persisted_row_opt.is_present()) {
            Qlite.Row persisted_row = (!) persisted_row_opt.inner;
            cursor_preserved =
                ((string) persisted_row[audit_db.mam_catchup.to_id]) ==
                    expected_to_id &&
                ((long) persisted_row[audit_db.mam_catchup.to_time]) ==
                    expected_to_time;
        }
        if (!done || result_row != null ||
                fetch_result == HistorySync.FetchResult.SUCCESS ||
                get_mam_range_count_for_tests(account, room) != 1 ||
                !cursor_preserved ||
                audit_db.message.select()
                    .with<int>(audit_db.message.account_id, "=", account.id)
                    .count() != 0) {
            throw new IOError.FAILED(
                "readiness loss during a MAM page must fail the page without committing its cursor");
        }
    }

    private void test_mediated_invite_requires_join_and_forwards_current_stream() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_mediated_invite_audit.begin(stream_interactor, muc_manager,
                account, conversation, stream, (obj, res) => {
                    try {
                        run_mediated_invite_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out waiting for mediated invite audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            fail_if(failure != null, "mediated invite audit failed: %s".printf(
                failure ?? "unknown error"));
        });
    }

    private void test_mediated_invite_permission_matrix() {
        fail_if(!MucManager.mediated_invite_possible_for_state(
                Xmpp.Xep.Muc.Affiliation.OWNER,
                false),
            "owners must remain allowed when additional invitations are disabled");
        fail_if(!MucManager.mediated_invite_possible_for_state(
                Xmpp.Xep.Muc.Affiliation.ADMIN,
                false),
            "admins must remain allowed when additional invitations are disabled");
        fail_if(MucManager.mediated_invite_possible_for_state(
                Xmpp.Xep.Muc.Affiliation.NONE,
                false),
            "ejabberd's disabled occupant policy must deny an unaffiliated occupant");
        fail_if(MucManager.mediated_invite_possible_for_state(
                Xmpp.Xep.Muc.Affiliation.MEMBER,
                false),
            "a member must not gain invitation privilege from a disabled policy");
        fail_if(!MucManager.mediated_invite_possible_for_state(
                Xmpp.Xep.Muc.Affiliation.MEMBER,
                true),
            "an enabled policy must allow a member independently of voice");
        fail_if(!MucManager.mediated_invite_possible_for_state(
                Xmpp.Xep.Muc.Affiliation.NONE,
                true),
            "an enabled occupant policy must follow the room server's advertised scope");
        fail_if(!MucManager.mediated_invite_possible_for_state(
                Xmpp.Xep.Muc.Affiliation.MEMBER,
                null),
            "an unknown policy must remain server-authoritative");
    }

    private void test_allowinvites_config_roundtrip_updates_gate() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_allowinvites", "boolean", "0");
            stream.derive_disco_invite_policy_from_config = true;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, stream);
            establish_owner_context(stream, account, conversation);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_allowinvites_config_roundtrip_audit.begin(muc_manager,
                account, conversation, stream, (obj, res) => {
                    try {
                        run_allowinvites_config_roundtrip_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "allowinvites configuration roundtrip timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_allowinvites_config_roundtrip_audit(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        Xmpp.Xep.DataForms.DataForm enabled =
            build_allowinvites_transition_form(false, true);
        MucConfigSaveResult enabled_result = yield
            muc_manager.set_config_form_detailed(account,
                conversation.counterpart, enabled, false);
        Xmpp.Xep.Muc.Flag? flag = stream.get_flag(
            Xmpp.Xep.Muc.Flag.IDENTITY);
        if (enabled_result != MucConfigSaveResult.APPLIED || flag == null ||
                !((!) flag).has_current_room_features(
                    conversation.counterpart) ||
                ((!) flag).get_occupants_may_invite(
                    conversation.counterpart) != true) {
            throw new IOError.FAILED(
                "owner SET, GET readback and fresh disco must publish allowinvites=true");
        }

        stream.emit_presence(build_self_presence(conversation.counterpart,
            conversation.nickname, account.full_jid, "member",
            "participant"));
        Jid invitee = new Jid("config-invitee@example.test/device");
        MucInviteSendResult allowed = yield muc_manager.invite(account,
            conversation.counterpart, invitee, "enabled policy",
            MucInviteDelivery.MEDIATED);
        if (!allowed.sent || allowed.error != null ||
                stream.message_count != 1 ||
                stream.last_message_to !=
                    conversation.counterpart.bare_jid.to_string() ||
                !stream.last_message_has_muc_user) {
            throw new IOError.FAILED(
                "the verified enabled configuration must allow a member invite");
        }

        stream.emit_presence(build_self_presence(conversation.counterpart,
            conversation.nickname, account.full_jid, "owner",
            "moderator"));
        Xmpp.Xep.DataForms.DataForm disabled =
            build_allowinvites_transition_form(true, false);
        MucConfigSaveResult disabled_result = yield
            muc_manager.set_config_form_detailed(account,
                conversation.counterpart, disabled, false);
        stream.emit_presence(build_self_presence(conversation.counterpart,
            conversation.nickname, account.full_jid, "member",
            "participant"));
        MucInviteSendResult denied = yield muc_manager.invite(account,
            conversation.counterpart, invitee, "disabled policy",
            MucInviteDelivery.MEDIATED);
        if (disabled_result != MucConfigSaveResult.APPLIED ||
                !((!) flag).has_current_room_features(
                    conversation.counterpart) ||
                ((!) flag).get_occupants_may_invite(
                    conversation.counterpart) != false || denied.sent ||
                denied.error != "not-allowed" || stream.message_count != 1 ||
                stream.owner_config_set_count != 2 ||
                stream.owner_config_get_count != 2 ||
                stream.get_server_config_value_for_tests(
                    "muc#roomconfig_allowinvites") != "0") {
            throw new IOError.FAILED(
                "verified allowinvites=false must immediately block a member without sending");
        }
    }

    private static Xmpp.Xep.DataForms.DataForm
            build_allowinvites_transition_form(bool original, bool changed)
            throws Error {
        var form_node = new StanzaNode.build("x",
                Xmpp.Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "form")
            .put_node(build_config_field("muc#roomconfig_allowinvites",
                "boolean", original ? "1" : "0"));
        return parse_and_change_config_field(form_node,
            "muc#roomconfig_allowinvites", changed ? "1" : "0");
    }

    private async void run_mediated_invite_audit(
            StreamInteractor stream_interactor, MucManager muc_manager,
            Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        Jid invitee = new Jid("invitee@example.test/phone");
        int messages_before = stream.message_count;
        MucInviteSendResult not_joined = yield muc_manager.invite(account,
            conversation.counterpart, invitee, null,
            MucInviteDelivery.MEDIATED);
        if (not_joined.sent || not_joined.error != "not-joined" ||
                stream.message_count != messages_before) {
            throw new IOError.FAILED(
                "mediated invite must fail closed without a current joined room");
        }

        Xmpp.Xep.Muc.Flag? flag = stream.get_flag(
            Xmpp.Xep.Muc.Flag.IDENTITY);
        if (flag == null) {
            throw new IOError.FAILED("test setup missing MUC flag");
        }
        ((!) flag).set_muc_nick(conversation.counterpart.with_resource(
            conversation.nickname));
        stream.emit_presence(build_self_presence(conversation.counterpart,
            conversation.nickname, account.full_jid, "member",
            "participant"));

        Xmpp.Xep.Muc.Module muc_module = stream.get_module<
            Xmpp.Xep.Muc.Module>(Xmpp.Xep.Muc.Module.IDENTITY);
        stream.disco_invite_policy = 0;
        bool disabled_policy_loaded = yield muc_module.query_room_info(stream,
            conversation.counterpart);
        MucInviteSendResult denied = yield muc_manager.invite(account,
            conversation.counterpart, invitee, "Must not leave the client",
            MucInviteDelivery.MEDIATED);
        if (!disabled_policy_loaded || denied.sent ||
                denied.error != "not-allowed" ||
                stream.message_count != messages_before) {
            throw new IOError.FAILED(
                "a fresh disabled room policy must block a member before writing a stanza");
        }

        stream.disco_error_condition = "service-unavailable";
        bool failed_refresh = yield muc_module.query_room_info(stream,
            conversation.counterpart);
        stream.disco_error_condition = null;
        if (failed_refresh ||
                !muc_manager.mediated_invite_possible(account,
                    conversation.counterpart)) {
            throw new IOError.FAILED(
                "a failed policy refresh must not turn a stale denial into local authority");
        }
        MucInviteSendResult fallback_sent = yield muc_manager.invite(account,
            conversation.counterpart, invitee,
            "Server decides after refresh failure",
            MucInviteDelivery.MEDIATED);
        if (!fallback_sent.sent || fallback_sent.error != null ||
                stream.message_count != messages_before + 1 ||
                stream.last_message_to !=
                    conversation.counterpart.bare_jid.to_string() ||
                !stream.last_message_has_muc_user) {
            throw new IOError.FAILED(
                "a failed policy refresh must leave the mediated send path server-authoritative");
        }

        stream.disco_invite_policy = 1;
        bool enabled_policy_loaded = yield muc_module.query_room_info(stream,
            conversation.counterpart);
        if (!enabled_policy_loaded ||
                !muc_manager.mediated_invite_possible(account,
                    conversation.counterpart)) {
            throw new IOError.FAILED(
                "a fresh enabled room policy must immediately allow the joined member");
        }

        string expected_room = conversation.counterpart.bare_jid.to_string();
        MucInviteSendResult sent = yield muc_manager.invite(account,
            conversation.counterpart, invitee, "Join us",
            MucInviteDelivery.MEDIATED);
        if (!sent.sent || sent.error != null ||
                stream.message_count != messages_before + 2 ||
                stream.last_message_to != expected_room ||
                !stream.last_message_has_muc_user) {
            throw new IOError.FAILED(
                "joined mediated invite must write exactly one MUC-user message to the bare room");
        }

        int forwarded = 0;
        string? forwarded_room = null;
        string? forwarded_invitee = null;
        string? forwarded_condition = null;
        string? forwarded_text = null;
        muc_manager.invite_failed.connect((failed_account, room, target,
                condition, text) => {
            if (failed_account != account) return;
            forwarded++;
            forwarded_room = room.to_string();
            forwarded_invitee = target.to_string();
            forwarded_condition = condition;
            forwarded_text = text;
        });
        muc_module = stream_interactor.module_manager.get_module<
            Xmpp.Xep.Muc.Module>(account, Xmpp.Xep.Muc.Module.IDENTITY);
        var stale_stream = new MucManagerAuditStream(
            new Jid("stale.example.test"), conversation.counterpart,
            conversation.nickname);
        muc_module.invite_failed(stale_stream, conversation.counterpart,
            invitee.bare_jid, ErrorStanza.CONDITION_FORBIDDEN, "stale");
        muc_module.invite_failed(stream, conversation.counterpart,
            invitee.bare_jid, ErrorStanza.CONDITION_FORBIDDEN,
            "role changed");
        if (forwarded != 1 ||
                forwarded_room != expected_room ||
                forwarded_invitee != invitee.bare_jid.to_string() ||
                forwarded_condition != ErrorStanza.CONDITION_FORBIDDEN ||
                forwarded_text != "role changed") {
            throw new IOError.FAILED(
                "invite failure forwarding must be account-scoped to the current stream");
        }
    }

    private void test_active_muc_survives_bookmark_removal() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(MucManager.IDENTITY);

            muc_manager.handle_conference_removed_for_tests(account, conversation.counterpart);

            fail_if_not(conversation.active, "bookmark removal must not close an active MUC conversation");
        });
    }

    private void test_force_rejoin_bypasses_local_join_cache() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"), conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account, stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_force_rejoin_bypasses_local_join_cache.begin(muc_manager, account, conversation, stream, (obj, res) => {
                try {
                    run_force_rejoin_bypasses_local_join_cache.end(res);
                } catch (Error e) {
                    failure = e.message;
                }
                loop.quit();
            });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out waiting for force-rejoin audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);

            fail_if(failure != null, "force-rejoin audit failed: %s".printf(failure ?? "unknown error"));
        });
    }

    private void test_manual_rejoin_after_leave_bypasses_stale_own_nick() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"), conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account, stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_manual_rejoin_after_leave_bypasses_stale_own_nick.begin(muc_manager, account, conversation, stream, (obj, res) => {
                try {
                    run_manual_rejoin_after_leave_bypasses_stale_own_nick.end(res);
                } catch (Error e) {
                    failure = e.message;
                }
                loop.quit();
            });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out waiting for manual rejoin after leave audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);

            fail_if(failure != null, "manual rejoin after leave audit failed: %s".printf(failure ?? "unknown error"));
        });
    }

    private void test_permanent_leave_closes_before_bookmark_remove_completes() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() {
                jid=conversation.counterpart, nick=conversation.nickname,
                autojoin=true
            });
            provider.defer_next_remove = true;
            muc_manager.set_bookmarks_provider_for_tests(account, provider);

            int removed_signals = 0;
            ulong handler = muc_manager.conference_removed.connect((a, room) => {
                if (a.equals(account) &&
                        room.equals_bare(conversation.counterpart)) {
                    removed_signals++;
                }
            });
            string? failure = null;
            muc_manager.leave_permanently.begin(account,
                conversation.counterpart, (obj, res) => {
                    try {
                        muc_manager.leave_permanently.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                });
            drain_muc_audit_context();

            fail_if(failure != null,
                "local permanent leave must not wait for bookmark sync");
            fail_if_not(provider.remove_pending,
                "bookmark removal must still be deferred by the audit backend");
            fail_if(conversation.active,
                "the conversation must close before deferred bookmark completion");
            fail_if(stream.unavailable_presence_count != 1,
                "permanent leave must send unavailable presence immediately");
            fail_if(removed_signals != 1,
                "local permanent leave must publish one removal transition");
            fail_if_not(muc_manager
                .is_pending_permanent_bookmark_removal_for_tests(account,
                    conversation.counterpart),
                "the deferred server removal must already have a durable intent");
            Database db = ((MucManagerTestApplication)
                GLib.Application.get_default()).db;
            string? persisted = db.account_settings.get_value(account.id,
                "muc-pending-bookmark-removals-v1");
            fail_if(persisted == null || !((!) persisted).contains(
                    conversation.counterpart.bare_jid.to_string()),
                "the tombstone must be durable at the local-close boundary");

            provider.complete_remove(true);
            drain_muc_audit_context();
            SignalHandler.disconnect(muc_manager, handler);
        });
    }

    private void test_permanent_leave_failure_keeps_local_state_and_intent() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() {
                jid=conversation.counterpart, nick=conversation.nickname,
                autojoin=true
            });
            provider.defer_next_remove = true;
            muc_manager.set_bookmarks_provider_for_tests(account, provider);

            muc_manager.leave_permanently.begin(account,
                conversation.counterpart);
            drain_muc_audit_context();
            provider.complete_remove(false);
            drain_muc_audit_context();

            fail_if(conversation.active ||
                    stream.unavailable_presence_count != 1,
                "bookmark failure must not roll back the completed local leave");
            fail_if_not(muc_manager.is_permanent_leave_marked_for_tests(
                    account, conversation.counterpart),
                "bookmark failure must retain the local rejoin block");
            fail_if_not(muc_manager
                .is_pending_permanent_bookmark_removal_for_tests(account,
                    conversation.counterpart),
                "bookmark failure must retain the durable removal intent");
            Database db = ((MucManagerTestApplication)
                GLib.Application.get_default()).db;
            string? persisted = db.account_settings.get_value(account.id,
                "muc-pending-bookmark-removals-v1");
            fail_if(persisted == null || !((!) persisted).contains(
                    conversation.counterpart.bare_jid.to_string()),
                "bookmark failure must retain the removal intent in account_settings");
        });
    }

    private void test_permanent_leave_rejoin_supersedes_stale_remove() {
        run_permanent_leave_rejoin_case(false);
        run_permanent_leave_rejoin_case(true);
    }

    private void run_permanent_leave_rejoin_case(
            bool echo_before_completion) {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() {
                jid=conversation.counterpart, nick=conversation.nickname,
                autojoin=true
            });
            provider.defer_next_remove = true;
            muc_manager.set_bookmarks_provider_for_tests(account, provider);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_permanent_leave_rejoin_audit.begin(muc_manager, account,
                conversation, stream, provider, echo_before_completion,
                (obj, res) => {
                    try {
                        run_permanent_leave_rejoin_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "permanent leave/rejoin audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            fail_if(failure != null, failure ?? "stale remove audit failed");
        });
    }

    private void test_permanent_remove_echo_before_rejoin_is_consumed() {
        run_permanent_remove_echo_before_rejoin_case(true);
        run_permanent_remove_echo_before_rejoin_case(false);
    }

    private void run_permanent_remove_echo_before_rejoin_case(
            bool echo_before_callback) {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() {
                jid=conversation.counterpart, nick=conversation.nickname,
                autojoin=true
            });
            provider.defer_next_remove = true;
            muc_manager.set_bookmarks_provider_for_tests(account, provider);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_permanent_remove_echo_before_rejoin_audit.begin(muc_manager,
                account, conversation, stream, provider,
                echo_before_callback, (obj, res) => {
                    try {
                        run_permanent_remove_echo_before_rejoin_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "pre-rejoin remove echo audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            fail_if(failure != null, failure ??
                "pre-rejoin remove echo audit failed");
        });
    }

    private void test_displaced_destroy_remove_waiter_completes() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() {
                jid=conversation.counterpart, nick=conversation.nickname,
                autojoin=true
            });
            provider.defer_next_get = true;
            muc_manager.set_bookmarks_provider_for_tests(account, provider);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_displaced_destroy_remove_waiter_audit.begin(muc_manager,
                account, conversation, stream, provider, (obj, res) => {
                    try {
                        run_displaced_destroy_remove_waiter_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "displaced destroy remove waiter audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            fail_if(failure != null, failure ??
                "displaced destroy remove waiter audit failed");
        });
    }

    private void test_repeated_permanent_leave_is_locally_idempotent() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() {
                jid=conversation.counterpart, nick=conversation.nickname,
                autojoin=true
            });
            provider.defer_next_remove = true;
            muc_manager.set_bookmarks_provider_for_tests(account, provider);
            int removed_signals = 0;
            ulong handler = muc_manager.conference_removed.connect((a, room) => {
                if (a.equals(account) && room.equals_bare(
                        conversation.counterpart)) removed_signals++;
            });

            muc_manager.leave_permanently.begin(account,
                conversation.counterpart);
            drain_muc_audit_context();
            muc_manager.leave_permanently.begin(account,
                conversation.counterpart);
            drain_muc_audit_context();
            fail_if(stream.unavailable_presence_count != 1 ||
                    removed_signals != 1 || provider.remove_count != 1,
                "repeated permanent leave must reuse one local lifecycle and one active remove");

            provider.complete_remove(true);
            drain_muc_audit_context();
            fail_if(provider.remove_count != 1,
                "a queued duplicate must stop after the first remove clears its tombstone");
            SignalHandler.disconnect(muc_manager, handler);
        });
    }

    private void test_stale_provider_snapshot_keeps_pending_remove() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            var stale_provider = new MucManagerAuditBookmarksProvider();
            stale_provider.conferences.add(new Conference() {
                jid=conversation.counterpart, nick=conversation.nickname,
                autojoin=true
            });
            stale_provider.defer_next_remove = true;
            muc_manager.set_bookmarks_provider_for_tests(account,
                stale_provider);
            muc_manager.leave_permanently.begin(account,
                conversation.counterpart);
            drain_muc_audit_context();

            stale_provider.defer_next_get = true;
            muc_manager.handle_stream_negotiated_for_tests.begin(account,
                stream);
            drain_muc_audit_context();
            fail_if_not(stale_provider.get_pending,
                "audit setup must hold the old provider snapshot");
            stale_provider.conferences.clear();
            var current_provider = new MucManagerAuditBookmarksProvider();
            muc_manager.set_bookmarks_provider_for_tests(account,
                current_provider);
            stale_provider.complete_get();
            drain_muc_audit_context();

            fail_if_not(muc_manager
                .is_pending_permanent_bookmark_removal_for_tests(account,
                    conversation.counterpart),
                "a stale empty snapshot from a replaced provider must not clear the tombstone");
            stale_provider.complete_remove(false);
            drain_muc_audit_context();
        });
    }

    private void test_provider_swap_requeues_current_remove_intent() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            var stale_provider = new MucManagerAuditBookmarksProvider();
            stale_provider.conferences.add(new Conference() {
                jid=conversation.counterpart, autojoin=true
            });
            stale_provider.defer_next_remove = true;
            muc_manager.set_bookmarks_provider_for_tests(account,
                stale_provider);
            muc_manager.leave_permanently.begin(account,
                conversation.counterpart);
            drain_muc_audit_context();

            var current_provider = new MucManagerAuditBookmarksProvider();
            current_provider.conferences.add(new Conference() {
                jid=conversation.counterpart, autojoin=true
            });
            muc_manager.set_bookmarks_provider_for_tests(account,
                current_provider);
            stale_provider.complete_remove(true);
            drain_muc_audit_context();

            fail_if(current_provider.remove_count != 1 ||
                    muc_manager
                        .is_pending_permanent_bookmark_removal_for_tests(
                            account, conversation.counterpart),
                "provider replacement must requeue the current remove intent on the current provider");
        });
    }

    private void test_null_snapshot_retries_restored_pending_remove() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            Database db = ((MucManagerTestApplication)
                GLib.Application.get_default()).db;
            db.account_settings.upsert()
                .value(db.account_settings.account_id, account.id, true)
                .value(db.account_settings.key,
                    "muc-pending-bookmark-removals-v1", true)
                .value(db.account_settings.value,
                    conversation.counterpart.bare_jid.to_string() + "\n")
                .perform();
            var provider = new MucManagerAuditBookmarksProvider();
            provider.get_returns_null = true;
            muc_manager.set_bookmarks_provider_for_tests(account, provider);

            MainLoop loop = new MainLoop();
            bool completed = false;
            muc_manager.handle_stream_negotiated_for_tests.begin(account,
                stream, (obj, res) => {
                    muc_manager.handle_stream_negotiated_for_tests.end(res);
                    completed = true;
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            drain_muc_audit_context();

            fail_if(!completed || provider.remove_count != 1 ||
                    muc_manager
                        .is_pending_permanent_bookmark_removal_for_tests(
                            account, conversation.counterpart),
                "a null bookmark snapshot must still replay and complete the durable remove intent");
        });
    }

    private void test_add_bookmark_provider_swap_requeues_current_intent() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            var stale_provider = new MucManagerAuditBookmarksProvider();
            stale_provider.defer_next_add = true;
            muc_manager.set_bookmarks_provider_for_tests(account,
                stale_provider);
            Conference bookmark = new Conference() {
                jid=conversation.counterpart, nick=conversation.nickname,
                name="Provider Swap", password="swap-secret", autojoin=false
            };
            bool? result = null;
            muc_manager.add_bookmark.begin(account, bookmark, (obj, res) => {
                result = muc_manager.add_bookmark.end(res);
            });
            drain_muc_audit_context();
            fail_if_not(stale_provider.add_pending,
                "audit setup must hold the add on the stale provider");

            var current_provider = new MucManagerAuditBookmarksProvider();
            muc_manager.set_bookmarks_provider_for_tests(account,
                current_provider);
            stale_provider.complete_add(true);
            drain_muc_audit_context();

            Conference? repaired = null;
            foreach (Conference candidate in current_provider.conferences) {
                if (candidate.jid != null && ((!) candidate.jid).equals_bare(
                        conversation.counterpart)) repaired = candidate;
            }
            fail_if(result == null || (!) result ||
                    current_provider.add_count != 1 || repaired == null ||
                    ((!) repaired).autojoin ||
                    ((!) repaired).name != "Provider Swap" ||
                    ((!) repaired).password != "swap-secret",
                "a stale provider add must not publish success and must requeue the complete current bookmark intent");
        });
    }

    private void test_initial_bookmark_snapshot_emits_update() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() {
                jid=conversation.counterpart,
                nick=conversation.nickname,
                name="Initial Snapshot",
                autojoin=false
            });
            muc_manager.set_bookmarks_provider_for_tests(account, provider);

            int updates = 0;
            bool contains_room = false;
            ulong bookmark_handler = muc_manager.bookmarks_updated.connect((updated_account,
                    conferences) => {
                if (updated_account.id != account.id) return;
                updates++;
                foreach (Conference conference in conferences) {
                    if (conference.jid.equals_bare(
                            conversation.counterpart)) contains_room = true;
                }
            });

            MainLoop loop = new MainLoop();
            bool completed = false;
            bool timed_out = false;
            muc_manager.handle_stream_negotiated_for_tests.begin(account,
                stream, (obj, result) => {
                    muc_manager.handle_stream_negotiated_for_tests.end(result);
                    completed = true;
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                timed_out = true;
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (!timed_out) Source.remove(timeout_id);
            SignalHandler.disconnect(muc_manager, bookmark_handler);

            fail_if(timed_out || !completed || updates != 1 || !contains_room,
                "The first successful bookmark snapshot must publish one visible-room update after negotiation");
        });
    }

    private void test_room_avatar_reconnect_expires_previous_stream_ttl() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucRoomAvatarManager manager =
                start_room_avatar_manager_for_tests(stream_interactor,
                    account, conversation);
            manager.mark_room_checked_for_tests(account,
                conversation.counterpart);
            manager.mark_room_failed_for_tests(account,
                conversation.counterpart);
            fail_if(!manager.was_room_checked_recently_for_tests(account,
                    conversation.counterpart) ||
                    !manager.is_room_in_failure_cooldown_for_tests(account,
                        conversation.counterpart),
                "The room-avatar audit must begin with live success and failure TTL state");

            stream_interactor.connection_manager
                .set_connection_state_for_tests(account,
                    ConnectionManager.ConnectionState.DISCONNECTED);
            fail_if(manager.was_room_checked_recently_for_tests(account,
                    conversation.counterpart) ||
                    manager.is_room_in_failure_cooldown_for_tests(account,
                        conversation.counterpart),
                "A fresh stream must not inherit room-avatar success or failure TTL state after missing offline status-104 updates");
        }, true);
    }

    private void test_room_avatar_queue_refills_bookmarks_above_cap() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucRoomAvatarManager manager =
                start_room_avatar_manager_for_tests(stream_interactor,
                    account, conversation);
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            Account second = new Account(new Jid("bob@example.test"),
                "secret");
            second.enabled = true;
            second.persist(get_muc_audit_database());
            stream_interactor.module_manager.initialize(second);
            stream_interactor.account_added(second);
            attach_room_avatar_stream_for_tests(stream_interactor, second,
                conversation.counterpart, "bob");

            try {
                Jid shared_room = new Jid(
                    "shared-avatar@conference.example.test");
                var first_shared = new Gee.HashSet<Conference>(
                    Conference.hash_func, Conference.equals_func);
                first_shared.add(new Conference() {
                    jid=shared_room, nick="alice", autojoin=false
                });
                var second_shared = new Gee.HashSet<Conference>(
                    Conference.hash_func, Conference.equals_func);
                second_shared.add(new Conference() {
                    jid=shared_room, nick="bob", autojoin=false
                });
                muc_manager.bookmarks_updated(account, first_shared);
                muc_manager.bookmarks_updated(second, second_shared);
                fail_if(manager.queued_rooms_for_tests(account).length != 1 ||
                        manager.queued_rooms_for_tests(second).length != 1,
                    "The same bare room must retain independent avatar work for both accounts");

                var first_conferences = new Gee.HashSet<Conference>(
                    Conference.hash_func, Conference.equals_func);
                var second_conferences = new Gee.HashSet<Conference>(
                    Conference.hash_func, Conference.equals_func);
                first_conferences.add(new Conference() {
                    jid=shared_room, nick="alice", autojoin=false
                });
                second_conferences.add(new Conference() {
                    jid=shared_room, nick="bob", autojoin=false
                });
                for (int i = 0; i < 255; i++) {
                    first_conferences.add(new Conference() {
                        jid=new Jid(
                            "alice-avatar-%03d@conference.example.test".printf(i)),
                        nick="alice", autojoin=false
                    });
                    second_conferences.add(new Conference() {
                        jid=new Jid(
                            "bob-avatar-%03d@conference.example.test".printf(i)),
                        nick="bob", autojoin=false
                    });
                }

                muc_manager.bookmarks_updated(account, first_conferences);
                muc_manager.bookmarks_updated(second, second_conferences);
                fail_if(manager.queued_room_count_for_tests() != 128 ||
                        !manager.refill_needed_for_tests(),
                    "The active room-avatar queue must stay capped while retaining refill intent");

                Jid[] first_batch = manager.queued_rooms_for_tests(account);
                Jid[] second_batch = manager.queued_rooms_for_tests(second);
                fail_if(first_batch.length + second_batch.length != 128,
                    "The first bounded room-avatar batch must contain 128 distinct account-room keys");
                foreach (Jid room in first_batch) {
                    muc_manager.conference_removed(account, room);
                }
                foreach (Jid room in second_batch) {
                    muc_manager.conference_removed(second, room);
                }
                manager.drain_for_tests();

                fail_if(manager.queued_room_count_for_tests() != 128 ||
                        manager.queued_rooms_for_tests(account).length != 64 ||
                        manager.queued_rooms_for_tests(second).length != 64 ||
                        !manager.refill_needed_for_tests(),
                    "A refill batch must alternate connected accounts without exceeding the global cap");
            } finally {
                stream_interactor.connection_manager
                    .set_connection_state_for_tests(second,
                        ConnectionManager.ConnectionState.DISCONNECTED);
                stream_interactor.account_removed(second);
                stream_interactor.module_manager.remove(second);
            }
        }, true);
    }

    private void test_room_avatar_disconnect_cancels_active_iq() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucRoomAvatarManager.start(stream_interactor);
            MucRoomAvatarManager manager = (!) stream_interactor.get_module<
                MucRoomAvatarManager>(MucRoomAvatarManager.IDENTITY);
            MucManagerAuditStream stream =
                attach_room_avatar_stream_for_tests(stream_interactor,
                    account, conversation.counterpart,
                    conversation.nickname);
            stream.defer_disco_info = true;
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var conferences = new Gee.HashSet<Conference>(
                Conference.hash_func, Conference.equals_func);
            conferences.add(new Conference() {
                jid=conversation.counterpart,
                nick=conversation.nickname,
                autojoin=false
            });

            muc_manager.bookmarks_updated(account, conferences);
            manager.drain_for_tests();
            fail_if(stream.held_disco_count != 1 ||
                    !manager.has_active_work_for_tests(account),
                "The cancellation audit must begin with one active room-avatar disco IQ");

            stream_interactor.connection_manager
                .set_connection_state_for_tests(account,
                    ConnectionManager.ConnectionState.DISCONNECTED);
            fail_if(!wait_for_room_avatar_idle(manager, account, 2000),
                "Disconnect must cancel and retire the active room-avatar IQ");
            fail_if(manager.queued_room_count_for_tests() != 0 ||
                    manager.has_drain_source_for_tests(),
                "Disconnect must leave no queued room-avatar work or timer source");

            stream.release_held_disco_successes();
            MainContext context = MainContext.@default();
            while (context.pending()) context.iteration(false);
            fail_if(manager.has_active_work_for_tests(account) ||
                    manager.queued_room_count_for_tests() != 0 ||
                    manager.has_drain_source_for_tests(),
                "A late IQ result must not revive cancelled room-avatar work");
        }, true);
    }

    private bool wait_for_room_avatar_idle(MucRoomAvatarManager manager,
            Account account, int timeout_ms) {
        MainContext context = MainContext.@default();
        int64 deadline = get_monotonic_time() + timeout_ms * 1000;
        while (manager.has_active_work_for_tests(account) &&
                get_monotonic_time() < deadline) {
            while (context.pending()) context.iteration(false);
            if (manager.has_active_work_for_tests(account)) {
                Thread.usleep(1000);
            }
        }
        while (context.pending()) context.iteration(false);
        return !manager.has_active_work_for_tests(account);
    }

    private MucRoomAvatarManager start_room_avatar_manager_for_tests(
            StreamInteractor stream_interactor, Account account,
            Conversation conversation) throws Error {
        MucRoomAvatarManager.start(stream_interactor);
        MucRoomAvatarManager manager = (!) stream_interactor.get_module<
            MucRoomAvatarManager>(MucRoomAvatarManager.IDENTITY);
        attach_room_avatar_stream_for_tests(stream_interactor, account,
            conversation.counterpart, conversation.nickname);
        return manager;
    }

    private MucManagerAuditStream attach_room_avatar_stream_for_tests(
            StreamInteractor stream_interactor, Account account, Jid room,
            string nick) throws Error {
        var stream = new MucManagerAuditStream(new Jid("example.test"),
            room, nick);
        attach_muc_stream_modules_for_tests(stream_interactor, account,
            stream);
        stream.negotiation_complete = true;
        stream_interactor.connection_manager.set_connected_stream_for_tests(
            account, stream);
        return stream;
    }

    private void test_part_recreates_bookmark_removed_by_stale_generation() {
        run_part_after_stale_remove_case(false);
        run_part_after_stale_remove_case(true);
    }

    private void run_part_after_stale_remove_case(
            bool callback_before_part) {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() {
                jid=conversation.counterpart, nick=conversation.nickname,
                name="Audit Room", autojoin=true
            });
            provider.defer_next_remove = true;
            muc_manager.set_bookmarks_provider_for_tests(account, provider);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_part_after_stale_remove_audit.begin(muc_manager, account,
                conversation, stream, provider, callback_before_part,
                (obj, res) => {
                    try {
                        run_part_after_stale_remove_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "part-after-stale-remove audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            fail_if(failure != null, failure ??
                "part-after-stale-remove audit failed");
        });
    }

    private void test_manual_bookmark_remove_notifies_exactly_once() {
        run_manual_bookmark_remove_order_audit(true);
        run_manual_bookmark_remove_order_audit(false);
    }

    private void run_manual_bookmark_remove_order_audit(
            bool event_before_completion) {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            var provider = new MucManagerAuditBookmarksProvider();
            Conference bookmark = new Conference() {
                jid=conversation.counterpart, nick=conversation.nickname,
                autojoin=true
            };
            provider.conferences.add(bookmark);
            provider.defer_next_remove = true;
            muc_manager.set_bookmarks_provider_for_tests(account, provider);
            int removed_signals = 0;
            ulong handler = muc_manager.conference_removed.connect((a, room) => {
                if (a.equals(account) && room.equals_bare(
                        conversation.counterpart)) removed_signals++;
            });
            bool? result = null;
            muc_manager.remove_bookmark.begin(account, bookmark, (obj, res) => {
                result = muc_manager.remove_bookmark.end(res);
            });
            drain_muc_audit_context();
            if (event_before_completion) {
                muc_manager.handle_conference_removed_for_tests(account,
                    conversation.counterpart);
            }
            provider.complete_remove(true);
            drain_muc_audit_context();
            if (!event_before_completion) {
                muc_manager.handle_conference_removed_for_tests(account,
                    conversation.counterpart);
            }
            fail_if(result != true || removed_signals != 1,
                "manual remove completion and provider retract must notify exactly once in either order");
            SignalHandler.disconnect(muc_manager, handler);
        });
    }

    private void test_manual_remove_add_race_preserves_new_bookmark() {
        run_manual_remove_add_race_case(true);
        run_manual_remove_add_race_case(false);
    }

    private void run_manual_remove_add_race_case(bool echo_before_callback) {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            var provider = new MucManagerAuditBookmarksProvider();
            Conference old_bookmark = new Conference() {
                jid=conversation.counterpart, nick=conversation.nickname,
                name="Old Bookmark", autojoin=true
            };
            provider.conferences.add(old_bookmark);
            provider.defer_next_remove = true;
            muc_manager.set_bookmarks_provider_for_tests(account, provider);
            int removed_signals = 0;
            ulong handler = muc_manager.conference_removed.connect((a, room) => {
                if (a.equals(account) && room.equals_bare(
                        conversation.counterpart)) removed_signals++;
            });
            bool? remove_result = null;
            muc_manager.remove_bookmark.begin(account, old_bookmark,
                (obj, res) => {
                    remove_result = muc_manager.remove_bookmark.end(res);
                });
            drain_muc_audit_context();
            fail_if_not(provider.remove_pending,
                "audit setup must hold manual remove G1");

            Conference new_bookmark = new Conference() {
                jid=conversation.counterpart, nick=conversation.nickname,
                name="New Bookmark", password="new-secret", autojoin=false
            };
            bool? add_result = null;
            muc_manager.add_bookmark.begin(account, new_bookmark,
                (obj, res) => {
                    add_result = muc_manager.add_bookmark.end(res);
                });
            drain_muc_audit_context();
            if (echo_before_callback) {
                muc_manager.handle_conference_removed_for_tests(account,
                    conversation.counterpart);
            }
            provider.complete_remove(true);
            drain_muc_audit_context();
            if (!echo_before_callback) {
                muc_manager.handle_conference_removed_for_tests(account,
                    conversation.counterpart);
                drain_muc_audit_context();
            }

            Conference? preserved = null;
            foreach (Conference candidate in provider.conferences) {
                if (candidate.jid != null && ((!) candidate.jid).equals_bare(
                        conversation.counterpart)) preserved = candidate;
            }
            fail_if(add_result != true || remove_result != false ||
                    removed_signals != 0 || preserved == null ||
                    ((!) preserved).autojoin ||
                    ((!) preserved).name != "New Bookmark" ||
                    ((!) preserved).password != "new-secret",
                "stale manual remove G1 must preserve and repair add G2 without a removal signal");

            int adds_before_legitimate_remove = provider.add_count;
            muc_manager.handle_conference_removed_for_tests(account,
                conversation.counterpart);
            drain_muc_audit_context();
            fail_if(removed_signals != 1 || provider.add_count !=
                    adds_before_legitimate_remove,
                "the old remove echo must be consumed exactly once before a later legitimate remove");
            SignalHandler.disconnect(muc_manager, handler);
        });
    }

    private void test_worker_start_rejection_preserves_room_lifecycle() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            bool lifecycle_signalled = false;
            bool generation_visible_at_boundary = false;
            ulong handler = muc_manager.room_initial_sync_started.connect(
                (delivered_account, room) => {
                    if (!delivered_account.equals(account) ||
                            !room.equals_bare(conversation.counterpart)) return;
                    lifecycle_signalled = true;
                    generation_visible_at_boundary =
                        muc_manager.get_room_occupant_generation(account,
                            room) != null;
                });
            muc_manager.reject_muc_occupant_worker_starts_for_tests();

            MainLoop loop = new MainLoop();
            string? failure = null;
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*MUC occupant worker rejected room start*");
            muc_manager.join.begin(account, conversation.counterpart,
                conversation.nickname, null, true, null, false, false,
                (obj, res) => {
                    try {
                        Xmpp.Xep.Muc.JoinResult? result =
                            muc_manager.join.end(res);
                        validate_join_result(result,
                            "worker-rejected MUC join");
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out waiting for worker-rejected MUC join";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            GLib.Test.assert_expected_messages();
            SignalHandler.disconnect(muc_manager, handler);

            fail_if(failure != null,
                "worker-rejected join failed: %s".printf(
                    failure ?? "unknown error"));
            fail_if(lifecycle_signalled,
                "A rejected worker start must not publish a lifecycle boundary");
            fail_if(generation_visible_at_boundary,
                "A rejected worker start must not expose an unowned generation");
            fail_if(muc_manager.get_room_occupant_generation(account,
                    conversation.counterpart) != null,
                "A rejected worker start must leave no reusable generation");
        });
    }

    private void test_repeated_account_removal_is_safe() {
        with_active_muc((stream_interactor, account, conversation) => {
            stream_interactor.account_removed(account);
            stream_interactor.account_removed(account);
        });
    }

    private void test_timed_ban_reason_parser_is_exact() {
        fail_if(!MucManager.is_dinox_timed_ban_reason("Banned for 10 minutes"),
            "DinoX's exact timed-ban reason must be recognized");
        fail_if(MucManager.is_dinox_timed_ban_reason("admin action"),
            "Unrelated words containing 'min' must never be treated as timed bans");
        fail_if(MucManager.is_dinox_timed_ban_reason("Banned for zero minutes"),
            "Malformed timed-ban reasons must be rejected");
        fail_if(MucManager.is_dinox_timed_ban_reason("Banned for 0 minutes"),
            "Non-positive timed-ban durations must be rejected");
        fail_if(MucManager.is_dinox_timed_ban_reason("Banned for 10 bananas"),
            "A timed-ban reason must have the exact DinoX suffix");
        fail_if(MucManager.is_dinox_timed_ban_reason("Banned for 10 minutes later"),
            "A timed-ban reason must not accept trailing text");
    }

    private void test_muc_affiliation_permission_matrix_matches_xep0045() {
        Xep.Muc.Affiliation owner = Xep.Muc.Affiliation.OWNER;
        Xep.Muc.Affiliation admin = Xep.Muc.Affiliation.ADMIN;
        Xep.Muc.Affiliation member = Xep.Muc.Affiliation.MEMBER;
        Xep.Muc.Affiliation outcast = Xep.Muc.Affiliation.OUTCAST;
        Xep.Muc.Affiliation none = Xep.Muc.Affiliation.NONE;

        fail_if(!MucManager.can_configure_room_affiliation(owner),
            "room owners must be able to open the owner configuration path");
        fail_if(MucManager.can_configure_room_affiliation(admin) ||
                MucManager.can_configure_room_affiliation(member) ||
                MucManager.can_configure_room_affiliation(null),
            "room configuration must fail closed for every non-owner state");
        fail_if(!MucManager.can_administer_room_affiliations(owner) ||
                !MucManager.can_administer_room_affiliations(admin) ||
                MucManager.can_administer_room_affiliations(member),
            "only owners and admins may enter affiliation administration");

        fail_if(!MucManager.can_manage_affiliation_list(owner, owner) ||
                !MucManager.can_manage_affiliation_list(owner, admin) ||
                !MucManager.can_manage_affiliation_list(owner, member) ||
                !MucManager.can_manage_affiliation_list(owner, outcast),
            "owners must see every affiliation list");
        fail_if(MucManager.can_manage_affiliation_list(admin, owner) ||
                MucManager.can_manage_affiliation_list(admin, admin) ||
                !MucManager.can_manage_affiliation_list(admin, member) ||
                !MucManager.can_manage_affiliation_list(admin, outcast),
            "admins may manage only member and outcast lists");

        fail_if(MucManager.can_request_affiliation_change(admin, owner,
                    outcast) ||
                MucManager.can_request_affiliation_change(admin, admin,
                    member),
            "admins must never alter owner or admin affiliations");
        fail_if(!MucManager.can_request_affiliation_change(admin, member,
                    outcast) ||
                !MucManager.can_request_affiliation_change(admin, outcast,
                    none) ||
                !MucManager.can_request_affiliation_change(admin, none,
                    member),
            "admins must retain the XEP-0045 member/outcast operations");
        fail_if(!MucManager.can_request_affiliation_change(owner, owner,
                    outcast),
            "owners may change another owner's affiliation per XEP-0045");
    }

    private void test_checked_muc_mutations_fail_closed() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            Xmpp.Xep.Muc.Flag? flag = stream.get_flag(
                Xmpp.Xep.Muc.Flag.IDENTITY);
            if (flag == null) throw new IOError.FAILED(
                "checked mutation test setup missing MUC flag");
            ((!) flag).set_muc_nick(conversation.counterpart.with_resource(
                conversation.nickname));
            stream.emit_presence(build_self_presence(conversation.counterpart,
                conversation.nickname, account.full_jid, "member",
                "participant"));
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "bob", account.full_jid, "none",
                "participant", new Jid("bob@example.test/device")));

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_checked_muc_mutation_guards.begin(muc_manager, account,
                conversation, stream, (obj, res) => {
                    try {
                        run_checked_muc_mutation_guards.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "checked MUC mutation guard audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_checked_muc_mutation_guards(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        bool role_denied = false;
        try {
            yield muc_manager.change_role_checked(account,
                conversation.counterpart, "bob", "none", "audit");
        } catch (IOError.PERMISSION_DENIED e) {
            role_denied = true;
        }
        if (!role_denied || stream.admin_iq_count != 0) {
            throw new IOError.FAILED(
                "unauthorized role mutation must fail before sending an IQ");
        }

        bool affiliation_denied = false;
        try {
            yield muc_manager.set_affiliation_checked(account,
                conversation.counterpart, new Jid("bob@example.test"),
                "member", "audit");
        } catch (IOError.PERMISSION_DENIED e) {
            affiliation_denied = true;
        }
        if (!affiliation_denied || stream.admin_iq_count != 0) {
            throw new IOError.FAILED(
                "unauthorized affiliation mutation must fail before sending an IQ");
        }

        bool subject_denied = false;
        try {
            muc_manager.change_subject_checked(account,
                conversation.counterpart, "unauthorized topic");
        } catch (IOError.PERMISSION_DENIED e) {
            subject_denied = true;
        }
        if (!subject_denied || stream.message_count != 0) {
            throw new IOError.FAILED(
                "unauthorized subject mutation must fail before sending a stanza");
        }

        stream.disco_subject_policy = 1;
        bool subject_policy_loaded = yield stream.get_module<
            Xmpp.Xep.Muc.Module>(Xmpp.Xep.Muc.Module.IDENTITY)
                .query_room_info(stream, conversation.counterpart);
        if (!subject_policy_loaded ||
                !muc_manager.can_change_subject(account,
                    conversation.counterpart)) {
            throw new IOError.FAILED(
                "a room disco policy must allow a participant to change the subject");
        }
        var participant_subject_written = new Gee.Promise<bool>();
        ulong participant_subject_handler = stream.message_written.connect(() => {
            participant_subject_written.set_value(true);
        });
        muc_manager.change_subject_checked(account, conversation.counterpart,
            "participant topic");
        if (stream.message_count == 0) {
            yield participant_subject_written.future.wait_async();
        }
        SignalHandler.disconnect(stream, participant_subject_handler);
        if (stream.message_count != 1 ||
                stream.last_message_subject != "participant topic") {
            throw new IOError.FAILED(
                "a policy-authorized participant must send one subject stanza");
        }

        stream.disco_subject_policy = 0;
        yield stream.get_module<Xmpp.Xep.Muc.Module>(
            Xmpp.Xep.Muc.Module.IDENTITY).query_room_info(stream,
                conversation.counterpart);
        subject_denied = false;
        try {
            muc_manager.change_subject_checked(account,
                conversation.counterpart, "denied participant topic");
        } catch (IOError.PERMISSION_DENIED e) {
            subject_denied = true;
        }
        if (!subject_denied || stream.message_count != 1) {
            throw new IOError.FAILED(
                "a disabled occupant subject policy must fail closed for participants");
        }

        stream.emit_presence(build_self_presence(conversation.counterpart,
            conversation.nickname, account.full_jid, "none", "moderator"));
        var subject_written = new Gee.Promise<bool>();
        ulong subject_handler = stream.message_written.connect(() => {
            subject_written.set_value(true);
        });
        muc_manager.change_subject_checked(account, conversation.counterpart,
            "moderator topic");
        if (stream.message_count < 2) {
            yield subject_written.future.wait_async();
        }
        SignalHandler.disconnect(stream, subject_handler);
        if (stream.message_count != 2 ||
                stream.last_message_to != conversation.counterpart.to_string() ||
                stream.last_message_type != Xmpp.MessageStanza.TYPE_GROUPCHAT ||
                stream.last_message_subject != "moderator topic") {
            throw new IOError.FAILED(
                "an authorized moderator subject change must add exactly one groupchat subject stanza");
        }

        // XEP-0045 8.4: voice cannot be revoked from an occupant whose
        // affiliation is at or above the moderator's level.
        bool mute_denied = false;
        try {
            yield muc_manager.change_role_checked(account,
                conversation.counterpart, "bob", "visitor", "audit mute");
        } catch (IOError.PERMISSION_DENIED e) {
            mute_denied = true;
        }
        if (!mute_denied || stream.admin_set_roles.size != 0) {
            throw new IOError.FAILED(
                "an unaffiliated moderator must not mute an equally affiliated participant");
        }
        stream.emit_presence(build_self_presence(conversation.counterpart,
            conversation.nickname, account.full_jid, "member", "moderator"));
        yield muc_manager.change_role_checked(account,
            conversation.counterpart, "bob", "visitor", "audit mute");
        if (stream.admin_set_roles.size != 1 ||
                stream.admin_set_roles[0] != "visitor") {
            throw new IOError.FAILED(
                "a member moderator must be able to mute an unaffiliated participant");
        }
        stream.emit_presence(build_occupant_presence(
            conversation.counterpart, "bob", account.full_jid, "member",
            "participant", new Jid("bob@example.test/device")));
        mute_denied = false;
        try {
            yield muc_manager.change_role_checked(account,
                conversation.counterpart, "bob", "visitor",
                "audit equal affiliation mute");
        } catch (IOError.PERMISSION_DENIED e) {
            mute_denied = true;
        }
        if (!mute_denied || stream.admin_set_roles.size != 1) {
            throw new IOError.FAILED(
                "a member moderator must not mute another member");
        }
        stream.emit_presence(build_self_presence(conversation.counterpart,
            conversation.nickname, account.full_jid, "admin", "moderator"));
        yield muc_manager.change_role_checked(account,
            conversation.counterpart, "bob", "visitor",
            "audit higher affiliation mute");
        if (stream.admin_set_roles.size != 2) {
            throw new IOError.FAILED(
                "an admin moderator must be able to mute a member participant");
        }

        // Owners may add a completely unknown/offline JID because they are
        // allowed to alter every source affiliation.
        stream.emit_presence(build_self_presence(conversation.counterpart,
            conversation.nickname, account.full_jid, "owner", "moderator"));
        Jid charlie = new Jid("charlie@example.test");
        yield muc_manager.set_affiliation_checked(account,
            conversation.counterpart, charlie, "member", "audit owner add");
        if (stream.get_server_affiliation_for_tests(charlie) != "member") {
            throw new IOError.FAILED(
                "an owner must be able to add a brand-new offline member");
        }

        // Admins must resolve unknown targets against the authoritative owner
        // and admin lists before treating them as affiliation=none.
        stream.emit_presence(build_self_presence(conversation.counterpart,
            conversation.nickname, account.full_jid, "admin", "moderator"));
        Jid protected_owner = new Jid("protected@example.test");
        stream.set_server_affiliation_for_tests(protected_owner, "owner");
        int sets_before_protected = stream.admin_set_count;
        bool protected_denied = false;
        try {
            yield muc_manager.set_affiliation_checked(account,
                conversation.counterpart, protected_owner, "member",
                "audit protected owner");
        } catch (IOError.PERMISSION_DENIED e) {
            protected_denied = true;
        }
        if (!protected_denied ||
                stream.admin_set_count != sets_before_protected ||
                stream.get_server_affiliation_for_tests(protected_owner) !=
                    "owner") {
            throw new IOError.FAILED(
                "an admin must not overwrite an unknown target that the owner list identifies as owner");
        }
        Jid new_admin_target = new Jid("new-member@example.test");
        yield muc_manager.set_affiliation_checked(account,
            conversation.counterpart, new_admin_target, "member",
            "audit verified admin add");
        if (stream.get_server_affiliation_for_tests(new_admin_target) !=
                "member") {
            throw new IOError.FAILED(
                "an admin must be able to add an offline member after owner/admin verification");
        }

        stream.emit_presence(build_self_presence(conversation.counterpart,
            conversation.nickname, account.full_jid, "owner", "moderator"));
        muc_manager.set_muc_occupant_room_generation_for_tests(account,
            conversation.counterpart, 1);
        bool generation_advanced = false;
        stream.admin_set_received.connect(() => {
            generation_advanced = true;
            muc_manager.advance_muc_occupant_room_generation_for_tests(
                account, conversation.counterpart);
        });

        yield muc_manager.set_affiliation_checked(account,
            conversation.counterpart, new Jid("bob@example.test"),
            "member", "audit stale generation");
        if (!generation_advanced ||
                stream.admin_set_count != sets_before_protected + 2) {
            throw new IOError.FAILED(
                "a confirmed in-flight affiliation IQ must report applied exactly once even if the room generation changes");
        }
    }

    private void test_muc_avatar_missing_vcard_allows_checked_owner_publish() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, stream);
            establish_owner_context(stream, account, conversation);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_muc_avatar_missing_vcard_audit.begin(muc_manager, account,
                conversation, stream, (obj, res) => {
                    try {
                        run_muc_avatar_missing_vcard_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "MUC avatar item-not-found audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_muc_avatar_missing_vcard_audit(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        MucManager.MucOwnerMutationContext? context =
            muc_manager.capture_current_owner_context(account,
                conversation.counterpart);
        if (context == null) {
            throw new IOError.FAILED(
                "MUC avatar audit requires a current Owner context");
        }

        stream.vcard_get_error_condition =
            Xmpp.ErrorStanza.CONDITION_ITEM_NOT_FOUND;
        Xmpp.Xep.VCard.VCardInfo? missing = yield
            muc_manager.fetch_muc_vcard_in_owner_context(account,
                (!) context);
        if (missing != null || stream.vcard_get_count != 1) {
            throw new IOError.FAILED(
                "a room item-not-found must be the checked empty vCard baseline");
        }

        var avatar_vcard = new Xmpp.Xep.VCard.VCardInfo();
        avatar_vcard.photo = new Bytes("muc-avatar-audit".data);
        avatar_vcard.photo_type = "image/png";
        yield muc_manager.publish_muc_vcard_in_owner_context(account,
            (!) context, avatar_vcard);
        if (stream.vcard_set_count != 1 ||
                !stream.last_vcard_set_had_photo) {
            throw new IOError.FAILED(
                "a missing room vCard must still allow one confirmed avatar publish");
        }

        // XEP-0486 removes an avatar by publishing an empty vCard.  A room
        // that already reports no vCard must remain an idempotent checked
        // mutation instead of failing before the IQ-set.
        missing = yield muc_manager.fetch_muc_vcard_in_owner_context(account,
            (!) context);
        if (missing != null) {
            throw new IOError.FAILED(
                "the removal baseline must preserve the missing-vCard result");
        }
        yield muc_manager.publish_muc_vcard_in_owner_context(account,
            (!) context, new Xmpp.Xep.VCard.VCardInfo());
        if (stream.vcard_get_count != 2 || stream.vcard_set_count != 2 ||
                stream.last_vcard_set_had_photo) {
            throw new IOError.FAILED(
                "removing a missing avatar must send one confirmed empty vCard");
        }

        int sets_before_rejections = stream.vcard_set_count;
        stream.vcard_get_error_condition =
            Xmpp.ErrorStanza.CONDITION_FORBIDDEN;
        bool forbidden_rejected = false;
        try {
            yield muc_manager.fetch_muc_vcard_in_owner_context(account,
                (!) context);
        } catch (IOError.FAILED error) {
            forbidden_rejected = true;
        }
        if (!forbidden_rejected ||
                stream.vcard_set_count != sets_before_rejections) {
            throw new IOError.FAILED(
                "forbidden room-vCard queries must remain fail-closed");
        }

        stream.vcard_get_error_condition =
            Xmpp.ErrorStanza.CONDITION_ITEM_NOT_FOUND;
        stream.vcard_response_from_override =
            "other@conference.example.test";
        bool wrong_sender_rejected = false;
        try {
            yield muc_manager.fetch_muc_vcard_in_owner_context(account,
                (!) context);
        } catch (IOError.FAILED error) {
            wrong_sender_rejected = true;
        }
        stream.vcard_response_from_override = null;
        if (!wrong_sender_rejected ||
                stream.vcard_set_count != sets_before_rejections) {
            throw new IOError.FAILED(
                "item-not-found from an unexpected sender must remain fail-closed");
        }
    }

    private void test_historical_message_identity_rejects_reused_nick() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            OccupantIdStore occupant_id_store = (!)
                stream_interactor.get_module<OccupantIdStore>(
                    OccupantIdStore.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);

            Jid occupant = conversation.counterpart.with_resource("sam");
            Jid alice = new Jid("alice-sender@example.test");
            Jid bob = new Jid("bob-sender@example.test");
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "sam", account.full_jid, "none",
                "participant", alice));

            var historical_real_jid = new Message("historical sender");
            historical_real_jid.real_jid = alice;
            fail_if(!muc_manager.current_occupant_matches_message_identity(
                    account, conversation.counterpart, occupant,
                    historical_real_jid),
                "a current occupant must match its historical bare real JID");

            // The same room/nick is now backed by a different real JID. Nick
            // equality must not authorize an action against the new person.
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "sam", account.full_jid, "none",
                "participant", bob));
            fail_if(muc_manager.current_occupant_matches_message_identity(
                    account, conversation.counterpart, occupant,
                    historical_real_jid),
                "a reused nick must not inherit historical message actions");

            int occupant_a_db_id = occupant_id_store.cache_occupant_id(account,
                "occupant-a", occupant);
            muc_manager.remember_private_message_peer_identity_for_tests(
                account, occupant, "occupant-id:occupant-a");
            var historical_occupant_id = new Message("historical occupant id");
            historical_occupant_id.occupant_db_id = occupant_a_db_id;
            fail_if(!muc_manager.current_occupant_matches_message_identity(
                    account, conversation.counterpart, occupant,
                    historical_occupant_id),
                "the current XEP-0421 occupant id must match its persisted id");

            occupant_id_store.cache_occupant_id(account, "occupant-b",
                occupant);
            muc_manager.remember_private_message_peer_identity_for_tests(
                account, occupant, "occupant-id:occupant-b");
            fail_if(muc_manager.current_occupant_matches_message_identity(
                    account, conversation.counterpart, occupant,
                    historical_occupant_id),
                "a reused nick with a different XEP-0421 id must fail closed");

            // If a message carries two stable identifiers, both must still
            // identify the current person.
            historical_occupant_id.real_jid = bob;
            fail_if(muc_manager.current_occupant_matches_message_identity(
                    account, conversation.counterpart, occupant,
                    historical_occupant_id),
                "matching real JID must not override a mismatching occupant id");
        });
    }

    private void test_stale_admin_room_context_is_fenced() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            muc_manager.set_muc_occupant_room_generation_for_tests(account,
                conversation.counterpart, 1);
            stream.set_server_affiliation_for_tests(
                new Jid("member@example.test"), "member");

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_stale_admin_room_context_audit.begin(muc_manager, account,
                conversation, stream, (obj, res) => {
                    try {
                        run_stale_admin_room_context_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "stale room-administration context audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_stale_admin_room_context_audit(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        MucManager.MucOwnerMutationContext? query_context =
            muc_manager.capture_current_muc_context(account,
                conversation.counterpart);
        if (query_context == null) {
            throw new IOError.FAILED(
                "the test room did not expose a current MUC context");
        }

        ulong query_handler = stream.affiliation_query_received.connect(
            (affiliation) => {
                muc_manager.advance_muc_occupant_room_generation_for_tests(
                    account, conversation.counterpart);
            });
        Gee.List<Jid>? stale_result = yield
            muc_manager.get_affiliations_in_context(account,
                (!) query_context, "member");
        SignalHandler.disconnect(stream, query_handler);
        if (stale_result != null) {
            throw new IOError.FAILED(
                "an affiliation result from an old room generation must be discarded");
        }
        Xep.Muc.Flag? flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
        Jid member = new Jid("member@example.test");
        if (flag == null || ((!) flag).has_affiliation(
                conversation.counterpart, member)) {
            throw new IOError.FAILED(
                "a stale affiliation result must not enter the live MUC cache");
        }

        MucManager.MucOwnerMutationContext? mutation_context =
            muc_manager.capture_current_muc_context(account,
                conversation.counterpart);
        if (mutation_context == null) {
            throw new IOError.FAILED(
                "the test room lost its replacement MUC context");
        }
        muc_manager.advance_muc_occupant_room_generation_for_tests(account,
            conversation.counterpart);
        bool cancelled = false;
        try {
            yield muc_manager.set_affiliation_checked_in_context(account,
                (!) mutation_context, new Jid("other@example.test"),
                "member", "stale admin dialog audit");
        } catch (IOError.CANCELLED e) {
            cancelled = true;
        }
        if (!cancelled || stream.admin_set_count != 0) {
            throw new IOError.FAILED(
                "a stale room-administration context must send no mutation IQ");
        }

        MucManager.MucOwnerMutationContext? role_context =
            muc_manager.capture_current_muc_context(account,
                conversation.counterpart);
        if (role_context == null) {
            throw new IOError.FAILED(
                "the test room lost its current role-mutation context");
        }
        muc_manager.advance_muc_occupant_room_generation_for_tests(account,
            conversation.counterpart);
        cancelled = false;
        try {
            yield muc_manager.change_role_checked_in_context(account,
                (!) role_context, "member", "none", "stale member menu audit");
        } catch (IOError.CANCELLED e) {
            cancelled = true;
        }
        if (!cancelled || stream.admin_set_count != 0) {
            throw new IOError.FAILED(
                "a stale member-menu role context must send no mutation IQ");
        }

        MucManager.MucOwnerMutationContext? subject_context =
            muc_manager.capture_current_muc_context(account,
                conversation.counterpart);
        if (subject_context == null) {
            throw new IOError.FAILED(
                "the test room lost its current subject-mutation context");
        }
        muc_manager.advance_muc_occupant_room_generation_for_tests(account,
            conversation.counterpart);
        cancelled = false;
        try {
            muc_manager.change_subject_checked_in_context(account,
                (!) subject_context, "stale room subject audit");
        } catch (IOError.CANCELLED e) {
            cancelled = true;
        }
        if (!cancelled || stream.message_count != 0) {
            throw new IOError.FAILED(
                "a stale room-subject context must send no groupchat stanza");
        }
    }

    private void test_loaded_config_and_destroy_confirmation_are_generation_fenced() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            muc_manager.set_muc_occupant_room_generation_for_tests(account,
                conversation.counterpart, 1);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_stale_owner_dialog_context_audit.begin(muc_manager, account,
                conversation, stream, (obj, res) => {
                    try {
                        run_stale_owner_dialog_context_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "stale room-owner dialog context audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_stale_owner_dialog_context_audit(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        MucManager.MucOwnerMutationContext? config_context =
            muc_manager.capture_current_owner_context(account,
                conversation.counterpart);
        if (config_context == null) {
            throw new IOError.FAILED(
                "the test room did not expose an Owner configuration context");
        }
        var form_node = new StanzaNode.build("x",
                Xmpp.Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "form")
            .put_node(build_config_field(
                "muc#roomconfig_membersonly", "boolean", "0"));
        Xmpp.Xep.DataForms.DataForm? form =
            Xmpp.Xep.DataForms.DataForm.create_from_node(form_node);
        if (form == null) {
            throw new IOError.FAILED("stale configuration form did not parse");
        }

        // This models a form loaded in generation A, followed by a same-stream
        // leave/rejoin before the user presses Apply.
        muc_manager.advance_muc_occupant_room_generation_for_tests(account,
            conversation.counterpart);
        MucConfigSaveResult result = yield
            muc_manager.set_config_form_detailed_in_context(account,
                (!) config_context, (!) form, false);
        if (result != MucConfigSaveResult.REJECTED ||
                stream.owner_config_set_count != 0 ||
                stream.occupant_presence_resync_count != 0) {
            throw new IOError.FAILED(
                "a form loaded in an old room generation must send no config IQ or occupant resync");
        }

        MucManager.MucOwnerMutationContext? destroy_context =
            muc_manager.capture_current_owner_context(account,
                conversation.counterpart);
        if (destroy_context == null) {
            throw new IOError.FAILED(
                "the replacement room did not expose an Owner context");
        }
        muc_manager.advance_muc_occupant_room_generation_for_tests(account,
            conversation.counterpart);
        bool rejected = false;
        try {
            yield muc_manager.destroy_room_detailed_in_context(account,
                (!) destroy_context, null);
        } catch (IOError.CANCELLED e) {
            rejected = true;
        } catch (IOError.PERMISSION_DENIED e) {
            rejected = true;
        }
        if (!rejected || stream.destroy_set_count != 0) {
            throw new IOError.FAILED(
                "a destroy confirmation from an old generation must send no IQ");
        }
    }

    private void test_context_config_resyncs_only_occupant_projection_changes() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_roomdesc", "text-single",
                "Original description");
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_enable_hats", "boolean", "0");
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_presencebroadcast", "list-multi",
                "moderator");
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream.negotiation_complete = true;
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, stream);
            establish_owner_context(stream, account, conversation);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_context_config_resync_audit.begin(muc_manager, account,
                conversation, stream, (obj, res) => {
                    try {
                        run_context_config_resync_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "context configuration resync audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private void test_confirmed_hats_and_presencebroadcast_update_live_worker() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            string[] initial_occupants = { "bob", "carol" };
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname,
                initial_occupants, null, "owner", "moderator");
            stream.initial_hatted_occupant = "bob";
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_enable_hats", "boolean", "1");
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_presencebroadcast", "list-multi",
                "participant");
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream.negotiation_complete = true;
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_confirmed_projection_live_worker_audit.begin(muc_manager,
                account, conversation, stream, (obj, res) => {
                    try {
                        run_confirmed_projection_live_worker_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "confirmed config projection live-worker audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_confirmed_projection_live_worker_audit(
            MucManager muc_manager, Account account,
            Conversation conversation, MucManagerAuditStream stream)
            throws Error {
        bool initial_sync_finished = false;
        var initial_sync = new Gee.Promise<bool>();
        ulong initial_sync_handler =
            muc_manager.room_initial_sync_finished.connect(
                (delivered_account, room) => {
                    if (initial_sync_finished ||
                            !delivered_account.equals(account) ||
                            !room.equals_bare(conversation.counterpart)) {
                        return;
                    }
                    initial_sync_finished = true;
                    initial_sync.set_value(true);
                });
        try {
            Xmpp.Xep.Muc.JoinResult? join_result = yield muc_manager.join(
                account, conversation.counterpart, conversation.nickname,
                null, true);
            validate_join_result(join_result,
                "confirmed config projection live-worker join");
            if (!initial_sync_finished) {
                try {
                    yield initial_sync.future.wait_async();
                } catch (Gee.FutureError error) {
                    throw new IOError.FAILED(
                        "initial live-worker wait failed: %s".printf(
                            error.message));
                }
            }

            MucRoomDelta? initial_snapshot =
                muc_manager.get_room_occupants_snapshot(account,
                    conversation.counterpart);
            if (initial_snapshot == null ||
                    ((!) initial_snapshot).occupant_count != 3 ||
                    !muc_manager.has_live_occupant_batching(account,
                        conversation.counterpart)) {
                throw new IOError.FAILED(
                    "confirmed config projection audit requires a committed three-occupant live worker");
            }

            string hatted_occupant_id = conversation.counterpart.bare_jid
                .with_resource("bob").to_string();
            bool initial_hat_found = false;
            for (uint i = 0; i < ((!) initial_snapshot).changed_count; i++) {
                MucOccupantSnapshot occupant =
                    ((!) initial_snapshot).changed_at(i);
                if (occupant.occupant_full_jid != hatted_occupant_id) continue;
                initial_hat_found = occupant.hat_count == 1 &&
                    occupant.hat_uri_at(0) == "urn:xmpp:hats:worker" &&
                    occupant.hat_title_at(0) == "Worker Hat";
                break;
            }
            if (!initial_hat_found) {
                throw new IOError.FAILED(
                    "initial live-worker snapshot must contain the foreign occupant's assigned Hat");
            }

            var hats_form_node = new StanzaNode.build("x",
                    Xmpp.Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "form")
                .put_node(build_config_field(
                    "muc#roomconfig_membersonly", "boolean", "0"))
                .put_node(build_config_field(
                    "muc#roomconfig_enable_hats", "boolean", "1"))
                .put_node(build_config_field(
                    "muc#roomconfig_presencebroadcast", "list-multi",
                    "participant"));
            Xmpp.Xep.DataForms.DataForm hats_form =
                parse_and_change_config_field(hats_form_node,
                    "muc#roomconfig_enable_hats", "0");
            MucManager.MucOwnerMutationContext? hats_context =
                muc_manager.capture_current_owner_context(account,
                    conversation.counterpart);
            if (hats_context == null) throw new IOError.FAILED(
                "confirmed Hats-disable audit requires a current Owner context");

            MucRoomDelta? hats_delta = null;
            var hats_batch = new Gee.Promise<MucRoomDelta>();
            ulong hats_batch_handler =
                muc_manager.room_occupants_changed_batch.connect(
                    (delivered_account, room, delta) => {
                        if (hats_delta != null ||
                                !delivered_account.equals(account) ||
                                !room.equals_bare(conversation.counterpart) ||
                                delta.full_snapshot ||
                                !delta.initial_sync_finished ||
                                delta.occupant_count != 3) return;
                        for (uint i = 0; i < delta.changed_count; i++) {
                            MucOccupantSnapshot occupant = delta.changed_at(i);
                            if (occupant.occupant_full_jid !=
                                    hatted_occupant_id ||
                                    occupant.hat_count != 0 ||
                                    (delta.changed_flags_at(i) &
                                        MucOccupantChange.HATS) == 0) continue;
                            hats_delta = delta;
                            hats_batch.set_value(delta);
                            break;
                        }
                    });
            try {
                MucConfigSaveResult hats_result = yield
                    muc_manager.set_config_form_detailed_in_context(account,
                        (!) hats_context, hats_form, false);
                if (hats_result != MucConfigSaveResult.APPLIED) {
                    throw new IOError.FAILED(
                        "verified Hats-disable save was not applied");
                }
                if (hats_delta == null) {
                    try {
                        hats_delta = yield hats_batch.future.wait_async();
                    } catch (Gee.FutureError error) {
                        throw new IOError.FAILED(
                            "confirmed Hats-disable live batch failed: %s"
                                .printf(error.message));
                    }
                }
            } finally {
                SignalHandler.disconnect(muc_manager, hats_batch_handler);
            }

            MucRoomDelta? hats_snapshot =
                muc_manager.get_room_occupants_snapshot(account,
                    conversation.counterpart);
            bool cleared_hat_found = false;
            if (hats_snapshot != null && ((!) hats_snapshot).full_snapshot &&
                    ((!) hats_snapshot).occupant_count == 3) {
                for (uint i = 0; i < ((!) hats_snapshot).changed_count; i++) {
                    MucOccupantSnapshot occupant =
                        ((!) hats_snapshot).changed_at(i);
                    if (occupant.occupant_full_jid == hatted_occupant_id) {
                        cleared_hat_found = occupant.hat_count == 0;
                        break;
                    }
                }
            }
            Jid hatted_occupant = conversation.counterpart.with_resource("bob");
            Xmpp.Xep.Muc.Flag muc_flag = stream.get_flag<
                Xmpp.Xep.Muc.Flag>(Xmpp.Xep.Muc.Flag.IDENTITY);
            if (hats_delta == null ||
                    ((!) hats_delta).degraded_partial ||
                    ((!) hats_delta).occupant_count != 3 ||
                    !cleared_hat_found ||
                    !stream_has_presence_occupant(stream,
                        conversation.counterpart, "bob") ||
                    !muc_flag.get_occupant_hats(hatted_occupant).is_empty ||
                    stream.occupant_presence_resync_count != 1) {
                throw new IOError.FAILED(
                    "confirmed Hats disable must clear the Hat through the live worker without removing its occupant");
            }

            var form_node = new StanzaNode.build("x",
                    Xmpp.Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "form")
                .put_node(build_config_field(
                    "muc#roomconfig_membersonly", "boolean", "0"))
                .put_node(build_config_field(
                    "muc#roomconfig_enable_hats", "boolean", "1"))
                .put_node(build_config_field(
                    "muc#roomconfig_presencebroadcast", "list-multi",
                    "participant"));
            Xmpp.Xep.DataForms.DataForm form = parse_and_change_config_field(
                form_node, "muc#roomconfig_presencebroadcast", "participant");
            foreach (Xmpp.Xep.DataForms.DataForm.Field field in form.fields) {
                if (field.var != "muc#roomconfig_presencebroadcast") continue;
                field.set_values(new Gee.ArrayList<string>());
            }

            MucManager.MucOwnerMutationContext? context =
                muc_manager.capture_current_owner_context(account,
                    conversation.counterpart);
            if (context == null) throw new IOError.FAILED(
                "empty presence-broadcast audit requires a current Owner context");

            MucRoomDelta? final_delta = null;
            var final_batch = new Gee.Promise<MucRoomDelta>();
            ulong batch_handler =
                muc_manager.room_occupants_changed_batch.connect(
                    (delivered_account, room, delta) => {
                        if (final_delta != null ||
                                !delivered_account.equals(account) ||
                                !room.equals_bare(conversation.counterpart) ||
                                delta.full_snapshot ||
                                !delta.initial_sync_finished ||
                                delta.occupant_count != 1) return;
                        final_delta = delta;
                        final_batch.set_value(delta);
                    });
            try {
                MucConfigSaveResult result = yield
                    muc_manager.set_config_form_detailed_in_context(account,
                        (!) context, form, false);
                if (result != MucConfigSaveResult.APPLIED) {
                    throw new IOError.FAILED(
                        "verified empty presence-broadcast save was not applied");
                }
                if (final_delta == null) {
                    try {
                        final_delta = yield final_batch.future.wait_async();
                    } catch (Gee.FutureError error) {
                        throw new IOError.FAILED(
                            "empty presence-broadcast live batch failed: %s"
                                .printf(error.message));
                    }
                }
            } finally {
                SignalHandler.disconnect(muc_manager, batch_handler);
            }

            MucRoomDelta? final_snapshot =
                muc_manager.get_room_occupants_snapshot(account,
                    conversation.counterpart);
            string own_occupant = conversation.counterpart.bare_jid
                .with_resource(conversation.nickname).to_string();
            if (final_delta == null ||
                    ((!) final_delta).degraded_partial ||
                    ((!) final_delta).occupant_count != 1 ||
                    final_snapshot == null ||
                    !((!) final_snapshot).full_snapshot ||
                    ((!) final_snapshot).occupant_count != 1 ||
                    ((!) final_snapshot).changed_count != 1 ||
                    ((!) final_snapshot).changed_at(0).occupant_full_jid !=
                        own_occupant ||
                    stream.occupant_presence_resync_count != 2) {
                throw new IOError.FAILED(
                    "empty presence-broadcast must reach the live worker and leave only self in its current snapshot");
            }
        } finally {
            SignalHandler.disconnect(muc_manager, initial_sync_handler);
        }
    }

    private async void run_context_config_resync_audit(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        var description_node = new StanzaNode.build("x",
                Xmpp.Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "form")
            .put_node(build_config_field(
                "muc#roomconfig_membersonly", "boolean", "0"))
            .put_node(build_config_field(
                "muc#roomconfig_roomdesc", "text-single",
                "Original description"))
            .put_node(build_config_field(
                "muc#roomconfig_enable_hats", "boolean", "0"));
        Xmpp.Xep.DataForms.DataForm description_form =
            parse_and_change_config_field(description_node,
                "muc#roomconfig_roomdesc", "Updated description");
        MucManager.MucOwnerMutationContext? context =
            muc_manager.capture_current_owner_context(account,
                conversation.counterpart);
        if (context == null) throw new IOError.FAILED(
            "configuration resync test requires a current owner context");
        MucConfigSaveResult description_result = yield
            muc_manager.set_config_form_detailed_in_context(account,
                (!) context, description_form, false);
        if (description_result != MucConfigSaveResult.APPLIED ||
                stream.occupant_presence_resync_count != 0) {
            throw new IOError.FAILED(
                "a description-only save must not refresh occupant presence");
        }

        var hats_node = new StanzaNode.build("x",
                Xmpp.Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "form")
            .put_node(build_config_field(
                "muc#roomconfig_membersonly", "boolean", "0"))
            .put_node(build_config_field(
                "muc#roomconfig_roomdesc", "text-single",
                "Updated description"))
            .put_node(build_config_field(
                "muc#roomconfig_enable_hats", "boolean", "0"));
        Xmpp.Xep.DataForms.DataForm hats_form = parse_and_change_config_field(
            hats_node, "muc#roomconfig_enable_hats", "1");
        context = muc_manager.capture_current_owner_context(account,
            conversation.counterpart);
        if (context == null) throw new IOError.FAILED(
            "the second save requires the same current owner lifecycle");
        MucConfigSaveResult hats_result = yield
            muc_manager.set_config_form_detailed_in_context(account,
                (!) context, hats_form, false);
        if (hats_result != MucConfigSaveResult.APPLIED ||
                stream.owner_config_set_count != 2 ||
                stream.owner_config_get_count != 2 ||
                stream.occupant_presence_resync_count != 1) {
            throw new IOError.FAILED(
                "one applied Hats change must request one merge-only occupant replay");
        }

        StanzaNode preserved_hatted_presence = build_occupant_presence(
            conversation.counterpart, "preserved-hat", account.full_jid,
            "member", "participant");
        preserved_hatted_presence.put_node(new StanzaNode.build("hats",
                NS_MUC_HATS)
            .add_self_xmlns()
            .put_node(new StanzaNode.build("hat", NS_MUC_HATS)
                .put_attribute("uri", "urn:xmpp:hats:preserved")
                .put_attribute("title", "Preserved")));
        stream.emit_presence(preserved_hatted_presence);
        Jid preserved_hatted_occupant = conversation.counterpart.with_resource(
            "preserved-hat");
        Xmpp.Xep.Muc.Flag muc_flag = stream.get_flag<Xmpp.Xep.Muc.Flag>(
            Xmpp.Xep.Muc.Flag.IDENTITY);
        if (muc_flag.get_occupant_hats(preserved_hatted_occupant).size != 1) {
            throw new IOError.FAILED(
                "unchanged Hats audit setup did not cache the assigned Hat");
        }

        var broadcast_node = new StanzaNode.build("x",
                Xmpp.Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "form")
            .put_node(build_config_field(
                "muc#roomconfig_membersonly", "boolean", "0"))
            .put_node(build_config_field(
                "muc#roomconfig_roomdesc", "text-single",
                "Updated description"))
            .put_node(build_config_field(
                "muc#roomconfig_enable_hats", "boolean", "1"))
            .put_node(build_config_field(
                "muc#roomconfig_presencebroadcast", "list-multi",
                "moderator"));
        Xmpp.Xep.DataForms.DataForm broadcast_form =
            parse_and_change_config_field(broadcast_node,
                "muc#roomconfig_presencebroadcast", "participant");
        stream.emit_presence(build_occupant_presence(
            conversation.counterpart, "visible-participant", account.full_jid,
            "member", "participant"));
        stream.emit_presence(build_occupant_presence(
            conversation.counterpart, "hidden-moderator", account.full_jid,
            "admin", "moderator"));
        context = muc_manager.capture_current_owner_context(account,
            conversation.counterpart);
        if (context == null) throw new IOError.FAILED(
            "the replacement save requires the refreshed owner lifecycle");
        MucConfigSaveResult broadcast_result = yield
            muc_manager.set_config_form_detailed_in_context(account,
                (!) context, broadcast_form, false);
        if (broadcast_result != MucConfigSaveResult.APPLIED ||
                stream.owner_config_set_count != 3 ||
                stream.owner_config_get_count != 3 ||
                stream.occupant_presence_resync_count != 2 ||
                !stream_has_presence_occupant(stream,
                    conversation.counterpart, "visible-participant") ||
                stream_has_presence_occupant(stream,
                    conversation.counterpart, "hidden-moderator") ||
                muc_flag.get_occupant_hats(
                    preserved_hatted_occupant).size != 1) {
            throw new IOError.FAILED(
                "verified presence-broadcast must remove only the excluded known role, preserve unchanged Hats, and request one merge-only replay");
        }

        var broadcast_expand_node = new StanzaNode.build("x",
                Xmpp.Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "form")
            .put_node(build_config_field(
                "muc#roomconfig_membersonly", "boolean", "0"))
            .put_node(build_config_field(
                "muc#roomconfig_enable_hats", "boolean", "1"))
            .put_node(build_config_field(
                "muc#roomconfig_presencebroadcast", "list-multi",
                "participant"));
        Xmpp.Xep.DataForms.DataForm broadcast_expand_form =
            parse_and_change_config_field(broadcast_expand_node,
                "muc#roomconfig_presencebroadcast", "participant");
        foreach (Xmpp.Xep.DataForms.DataForm.Field field in
                broadcast_expand_form.fields) {
            if (field.var != "muc#roomconfig_presencebroadcast") continue;
            var expanded_roles = new Gee.ArrayList<string>();
            expanded_roles.add("participant");
            expanded_roles.add("moderator");
            field.set_values(expanded_roles);
        }
        context = muc_manager.capture_current_owner_context(account,
            conversation.counterpart);
        if (context == null) throw new IOError.FAILED(
            "the presence-broadcast expansion requires the current owner lifecycle");
        int projection_change_events = 0;
        ulong projection_change_handler =
            muc_manager.room_occupant_projection_changed.connect(
                (delivered_account, room) => {
                    if (delivered_account.equals(account) &&
                            room.equals_bare(conversation.counterpart)) {
                        projection_change_events++;
                    }
                });
        MucConfigSaveResult broadcast_expand_result =
            MucConfigSaveResult.REJECTED;
        try {
            broadcast_expand_result = yield
                muc_manager.set_config_form_detailed_in_context(account,
                    (!) context, broadcast_expand_form, false);
        } finally {
            SignalHandler.disconnect(muc_manager,
                projection_change_handler);
        }
        if (broadcast_expand_result != MucConfigSaveResult.APPLIED ||
                stream.owner_config_set_count != 4 ||
                stream.owner_config_get_count != 4 ||
                stream.occupant_presence_resync_count != 3 ||
                projection_change_events != 1 ||
                !stream_has_presence_occupant(stream,
                    conversation.counterpart, "visible-participant")) {
            throw new IOError.FAILED(
                "verified presence-broadcast must invalidate stale UI projection caches even when zero occupants were removed");
        }

        stream.emit_presence(build_occupant_presence(
            conversation.counterpart, "empty-moderator", account.full_jid,
            "admin", "moderator"));
        var broadcast_empty_node = new StanzaNode.build("x",
                Xmpp.Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "form")
            .put_node(build_config_field(
                "muc#roomconfig_membersonly", "boolean", "0"))
            .put_node(build_config_field(
                "muc#roomconfig_enable_hats", "boolean", "1"))
            .put_node(build_config_field(
                "muc#roomconfig_presencebroadcast", "list-multi",
                "participant"));
        Xmpp.Xep.DataForms.DataForm broadcast_empty_form =
            parse_and_change_config_field(broadcast_empty_node,
                "muc#roomconfig_presencebroadcast", "participant");
        foreach (Xmpp.Xep.DataForms.DataForm.Field field in
                broadcast_empty_form.fields) {
            if (field.var != "muc#roomconfig_presencebroadcast") continue;
            field.set_values(new Gee.ArrayList<string>());
        }
        context = muc_manager.capture_current_owner_context(account,
            conversation.counterpart);
        if (context == null) throw new IOError.FAILED(
            "the empty presence-broadcast save requires the current owner lifecycle");
        projection_change_events = 0;
        projection_change_handler =
            muc_manager.room_occupant_projection_changed.connect(
                (delivered_account, room) => {
                    if (delivered_account.equals(account) &&
                            room.equals_bare(conversation.counterpart)) {
                        projection_change_events++;
                    }
                });
        MucConfigSaveResult broadcast_empty_result =
            MucConfigSaveResult.REJECTED;
        try {
            broadcast_empty_result = yield
                muc_manager.set_config_form_detailed_in_context(account,
                    (!) context, broadcast_empty_form, false);
        } finally {
            SignalHandler.disconnect(muc_manager,
                projection_change_handler);
        }
        if (broadcast_empty_result != MucConfigSaveResult.APPLIED ||
                stream.owner_config_set_count != 5 ||
                stream.owner_config_get_count != 5 ||
                stream.occupant_presence_resync_count != 4 ||
                projection_change_events != 1 ||
                stream_has_presence_occupant(stream,
                    conversation.counterpart, "visible-participant") ||
                stream_has_presence_occupant(stream,
                    conversation.counterpart, "preserved-hat") ||
                stream_has_presence_occupant(stream,
                    conversation.counterpart, "empty-moderator")) {
            throw new IOError.FAILED(
                "an explicitly empty presence-broadcast selection must immediately remove every known non-self role and invalidate the UI projection");
        }

        StanzaNode hatted_presence = build_occupant_presence(
            conversation.counterpart, "hatted-member", account.full_jid,
            "member", "participant");
        hatted_presence.put_node(new StanzaNode.build("hats", NS_MUC_HATS)
            .add_self_xmlns()
            .put_node(new StanzaNode.build("hat", NS_MUC_HATS)
                .put_attribute("uri", "urn:xmpp:hats:support")
                .put_attribute("title", "Support")));
        stream.emit_presence(hatted_presence);
        Jid hatted_occupant = conversation.counterpart.with_resource(
            "hatted-member");
        if (muc_flag.get_occupant_hats(hatted_occupant).size != 1) {
            throw new IOError.FAILED(
                "verified Hats-disable audit setup did not cache the Hat");
        }

        var hats_disable_node = new StanzaNode.build("x",
                Xmpp.Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "form")
            .put_node(build_config_field(
                "muc#roomconfig_membersonly", "boolean", "0"))
            .put_node(build_config_field(
                "muc#roomconfig_roomdesc", "text-single",
                "Updated description"))
            .put_node(build_config_field(
                "muc#roomconfig_enable_hats", "boolean", "1"))
            .put_node(build_config_field(
                "muc#roomconfig_presencebroadcast", "list-multi",
                "participant"));
        Xmpp.Xep.DataForms.DataForm hats_disable_form =
            parse_and_change_config_field(hats_disable_node,
                "muc#roomconfig_enable_hats", "0");
        context = muc_manager.capture_current_owner_context(account,
            conversation.counterpart);
        if (context == null) throw new IOError.FAILED(
            "the Hats-disable save requires the current owner lifecycle");
        MucConfigSaveResult hats_disable_result = yield
            muc_manager.set_config_form_detailed_in_context(account,
                (!) context, hats_disable_form, false);
        if (hats_disable_result != MucConfigSaveResult.APPLIED ||
                stream.owner_config_set_count != 6 ||
                stream.owner_config_get_count != 6 ||
                stream.occupant_presence_resync_count != 5 ||
                !muc_flag.get_occupant_hats(hatted_occupant).is_empty ||
                !stream_has_presence_occupant(stream,
                    conversation.counterpart, "hatted-member")) {
            throw new IOError.FAILED(
                "verified Hats disable must clear only Hats, preserve the occupant, and request one replay");
        }

        StanzaNode uncertain_presence = build_occupant_presence(
            conversation.counterpart, "unverified-participant",
            account.full_jid, "member", "participant");
        uncertain_presence.put_node(new StanzaNode.build("hats", NS_MUC_HATS)
            .add_self_xmlns()
            .put_node(new StanzaNode.build("hat", NS_MUC_HATS)
                .put_attribute("uri", "urn:xmpp:hats:unverified")
                .put_attribute("title", "Unverified")));
        stream.emit_presence(uncertain_presence);
        Jid uncertain_occupant = conversation.counterpart.with_resource(
            "unverified-participant");

        var unverified_node = new StanzaNode.build("x",
                Xmpp.Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "form")
            .put_node(build_config_field(
                "muc#roomconfig_membersonly", "boolean", "0"))
            .put_node(build_config_field(
                "muc#roomconfig_enable_hats", "boolean", "1"))
            .put_node(build_config_field(
                "muc#roomconfig_presencebroadcast", "list-multi",
                "participant"));
        Xmpp.Xep.DataForms.DataForm unverified_form =
            parse_and_change_config_field(unverified_node,
                "muc#roomconfig_presencebroadcast", "moderator");
        foreach (Xmpp.Xep.DataForms.DataForm.Field field in
                unverified_form.fields) {
            if (field.var == "muc#roomconfig_enable_hats") {
                field.set_value_string("0");
            }
        }
        context = muc_manager.capture_current_owner_context(account,
            conversation.counterpart);
        if (context == null) throw new IOError.FAILED(
            "the unverified save requires the current owner lifecycle");
        stream.apply_owner_config_set_values = false;
        GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
            "*changed server values could not be confirmed*");
        MucConfigSaveResult unverified_result = yield
            muc_manager.set_config_form_detailed_in_context(account,
                (!) context, unverified_form, false);
        GLib.Test.assert_expected_messages();
        if (unverified_result !=
                MucConfigSaveResult.APPLIED_SERVER_STATE_UNVERIFIED ||
                stream.owner_config_set_count != 7 ||
                stream.owner_config_get_count != 7 ||
                stream.occupant_presence_resync_count != 6 ||
                !stream_has_presence_occupant(stream,
                    conversation.counterpart, "unverified-participant") ||
                muc_flag.get_occupant_hats(uncertain_occupant).size != 1) {
            throw new IOError.FAILED(
                "unverified server state must request replay without locally deleting occupants or Hats");
        }
    }

    private void test_verified_whois_readback_fallback_is_privacy_authoritative() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_whois", "list-single", "moderators");
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream.negotiation_complete = true;
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, stream);
            establish_owner_context(stream, account, conversation);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_verified_whois_fallback_audit.begin(muc_manager, account,
                conversation, stream, (obj, res) => {
                    try {
                        run_verified_whois_fallback_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(8, () => {
                failure = "verified whois fallback audit timed out";
                timeout_id = 0;
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_verified_whois_fallback_audit(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        Jid room = conversation.counterpart;
        Jid peer = room.with_resource("whois-peer");
        Xmpp.Xep.Muc.Flag muc_flag = stream.get_flag<Xmpp.Xep.Muc.Flag>(
            Xmpp.Xep.Muc.Flag.IDENTITY);
        stream.disco_error_condition =
            Xmpp.ErrorStanza.CONDITION_SERVICE_UNAVAILABLE;

        MucConfigSaveResult anyone_result = yield save_whois_transition(
            muc_manager, account, room, "moderators", "anyone", stream,
            false, true);
        if (anyone_result != MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING ||
                muc_manager.get_room_real_jid_visibility(account, room) !=
                    Xmpp.Xep.Muc.RealJidVisibility.ANYONE ||
                stream.occupant_presence_resync_count != 1) {
            throw new IOError.FAILED(
                "verified whois=anyone must repair failed disco and request exactly one replay");
        }

        stream.emit_presence(build_occupant_presence(room, "whois-peer",
            account.full_jid, "member", "participant",
            new Jid("whois-peer@example.test/device")));
        if (muc_flag.get_real_jid(peer) == null) {
            throw new IOError.FAILED(
                "whois fallback audit could not cache a visible real JID");
        }

        MucConfigSaveResult moderators_result = yield save_whois_transition(
            muc_manager, account, room, "anyone", "moderators", stream,
            false, true);
        if (moderators_result !=
                    MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING ||
                muc_manager.get_room_real_jid_visibility(account, room) !=
                    Xmpp.Xep.Muc.RealJidVisibility.MODERATORS ||
                muc_flag.get_real_jid(peer) != null ||
                stream.occupant_presence_resync_count != 1) {
            throw new IOError.FAILED(
                "verified whois=moderators must immediately scrub a normal participant without replay");
        }

        MucConfigSaveResult restore_anyone_result = yield
            save_whois_transition(muc_manager, account, room, "moderators",
                "anyone", stream, false, true);
        if (restore_anyone_result !=
                    MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING ||
                muc_manager.get_room_real_jid_visibility(account, room) !=
                    Xmpp.Xep.Muc.RealJidVisibility.ANYONE ||
                stream.occupant_presence_resync_count != 2) {
            throw new IOError.FAILED(
                "restoring verified whois=anyone after failed disco must request one fresh replay");
        }
        stream.emit_presence(build_occupant_presence(room, "whois-peer",
            account.full_jid, "member", "participant",
            new Jid("whois-peer@example.test/device")));

        MucConfigSaveResult none_result = yield save_whois_transition(
            muc_manager, account, room, "anyone", "none", stream,
            false, true);
        if (none_result != MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING ||
                muc_manager.get_room_real_jid_visibility(account, room) !=
                    Xmpp.Xep.Muc.RealJidVisibility.NOBODY ||
                muc_flag.get_real_jid(peer) != null ||
                stream.occupant_presence_resync_count != 2) {
            throw new IOError.FAILED(
                "verified whois=none must fully scrub cached real JIDs without replay");
        }

        MucConfigSaveResult final_anyone_result = yield
            save_whois_transition(muc_manager, account, room, "none",
                "anyone", stream, false, true);
        if (final_anyone_result !=
                    MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING ||
                stream.occupant_presence_resync_count != 3) {
            throw new IOError.FAILED(
                "verified none-to-anyone fallback must request one replay");
        }
        stream.emit_presence(build_occupant_presence(room, "whois-peer",
            account.full_jid, "member", "participant",
            new Jid("whois-peer@example.test/device")));
        if (muc_flag.get_real_jid(peer) == null) {
            throw new IOError.FAILED(
                "unverified whois audit setup must retain one visible real JID");
        }

        stream.apply_owner_config_set_values = false;
        MucConfigSaveResult unverified_result = yield save_whois_transition(
            muc_manager, account, room, "anyone", "none", stream,
            true, true);
        if (unverified_result !=
                    MucConfigSaveResult.APPLIED_SERVER_STATE_UNVERIFIED ||
                muc_manager.get_room_real_jid_visibility(account, room) !=
                    Xmpp.Xep.Muc.RealJidVisibility.ANYONE ||
                muc_flag.get_real_jid(peer) == null ||
                stream.occupant_presence_resync_count != 4 ||
                stream.owner_config_set_count != 6 ||
                stream.owner_config_get_count != 6) {
            throw new IOError.FAILED(
                "unconfirmed owner readback must preserve privacy authority and live real JIDs while using only merge-only replay");
        }
    }

    private void test_successful_whois_disco_replay_is_not_duplicated() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_whois", "list-single", "none");
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream.negotiation_complete = true;
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, stream);
            establish_owner_context(stream, account, conversation);
            stream.emit_presence(build_self_presence(
                conversation.counterpart, conversation.nickname,
                account.full_jid, "owner", "moderator"));

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_successful_whois_disco_audit.begin(muc_manager, account,
                conversation, stream, (obj, res) => {
                    try {
                        run_successful_whois_disco_audit.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(8, () => {
                failure = "successful whois disco audit timed out";
                timeout_id = 0;
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_successful_whois_disco_audit(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        Jid room = conversation.counterpart;
        Jid peer = room.with_resource("whois-moderator-peer");
        Xmpp.Xep.Muc.Flag muc_flag = stream.get_flag<Xmpp.Xep.Muc.Flag>(
            Xmpp.Xep.Muc.Flag.IDENTITY);

        stream.disco_semi_anonymous = true;
        MucConfigSaveResult moderators_result = yield save_whois_transition(
            muc_manager, account, room, "none", "moderators", stream);
        if (moderators_result != MucConfigSaveResult.APPLIED ||
                muc_manager.get_room_real_jid_visibility(account, room) !=
                    Xmpp.Xep.Muc.RealJidVisibility.MODERATORS ||
                stream.occupant_presence_resync_count != 1) {
            throw new IOError.FAILED(
                "successful UNKNOWN-to-MODERATORS disco for a moderator must request exactly one replay");
        }

        stream.disco_semi_anonymous = false;
        stream.disco_non_anonymous = true;
        MucConfigSaveResult anyone_result = yield save_whois_transition(
            muc_manager, account, room, "moderators", "anyone", stream);
        if (anyone_result != MucConfigSaveResult.APPLIED ||
                muc_manager.get_room_real_jid_visibility(account, room) !=
                    Xmpp.Xep.Muc.RealJidVisibility.ANYONE ||
                stream.occupant_presence_resync_count != 2) {
            throw new IOError.FAILED(
                "successful whois=anyone disco plus owner wrapper must send one replay, never two");
        }
        stream.emit_presence(build_occupant_presence(room,
            "whois-moderator-peer", account.full_jid, "member",
            "participant", new Jid("whois-moderator-peer@example.test/device")));
        if (muc_flag.get_real_jid(peer) == null) {
            throw new IOError.FAILED(
                "moderator downgrade audit could not cache a visible real JID");
        }

        stream.disco_non_anonymous = false;
        stream.disco_semi_anonymous = true;
        MucConfigSaveResult downgrade_result = yield save_whois_transition(
            muc_manager, account, room, "anyone", "moderators", stream);
        if (downgrade_result != MucConfigSaveResult.APPLIED ||
                muc_manager.get_room_real_jid_visibility(account, room) !=
                    Xmpp.Xep.Muc.RealJidVisibility.MODERATORS ||
                stream.occupant_presence_resync_count != 2 ||
                muc_flag.get_real_jid(peer) == null ||
                stream.owner_config_set_count != 3 ||
                stream.owner_config_get_count != 3) {
            throw new IOError.FAILED(
                "successful ANYONE-to-MODERATORS disco for a moderator must retain JIDs and send no replay");
        }
    }

    private async MucConfigSaveResult save_whois_transition(
            MucManager muc_manager, Account account, Jid room,
            string old_value, string new_value,
            MucManagerAuditStream stream,
            bool expect_readback_warning = false,
            bool expect_disco_warning = false) throws Error {
        var form_node = new StanzaNode.build("x",
                Xmpp.Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "form")
            .put_node(build_config_field(
                "muc#roomconfig_membersonly", "boolean", "0"))
            .put_node(build_config_field(
                "muc#roomconfig_whois", "list-single", old_value));
        Xmpp.Xep.DataForms.DataForm form = parse_and_change_config_field(
            form_node, "muc#roomconfig_whois", new_value);
        MucManager.MucOwnerMutationContext? context =
            muc_manager.capture_current_owner_context(account, room);
        if (context == null) {
            throw new IOError.FAILED(
                "whois configuration audit lost its owner context");
        }
        if (expect_readback_warning) {
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*changed server values could not be confirmed*");
        }
        if (expect_disco_warning) {
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*refreshed room information could not be confirmed*");
        }
        MucConfigSaveResult result = yield
            muc_manager.set_config_form_detailed_in_context(account,
                (!) context, form, false);
        if (expect_readback_warning || expect_disco_warning) {
            GLib.Test.assert_expected_messages();
        }
        return result;
    }

    private void test_confirmed_role_change_waits_for_presence_without_replay() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream.negotiation_complete = true;
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, stream);
            establish_owner_context(stream, account, conversation);
            stream.emit_presence(build_self_presence(
                conversation.counterpart, conversation.nickname,
                account.full_jid, "owner", "moderator"));
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "visitor", account.full_jid,
                "none", "visitor"));

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_confirmed_role_change_without_replay.begin(muc_manager, account,
                conversation, stream, (obj, res) => {
                    try {
                        run_confirmed_role_change_without_replay.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "confirmed role Presence audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_confirmed_role_change_without_replay(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        int confirmations = 0;
        Jid? confirmed_occupant = null;
        Xmpp.Xep.Muc.Role? confirmed_role = null;
        ulong confirmation_handler =
            muc_manager.occupant_role_change_confirmed.connect(
                (delivered_account, occupant, role) => {
                    if (!delivered_account.equals(account)) return;
                    confirmations++;
                    confirmed_occupant = occupant;
                    confirmed_role = role;
                });
        MucManager.MucOwnerMutationContext? context =
            muc_manager.capture_current_muc_context(account,
                conversation.counterpart);
        if (context == null) {
            throw new IOError.FAILED(
                "role Presence test could not capture the room lifecycle");
        }
        try {
            yield muc_manager.change_role_checked_in_context(account,
                (!) context, "visitor", "participant", "voice granted");
            if (stream.occupant_presence_resync_count != 0) {
                throw new IOError.FAILED(
                    "a confirmed role IQ must not request an extra occupant replay");
            }

            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "visitor", account.full_jid,
                "none", "participant"));
        } finally {
            SignalHandler.disconnect(muc_manager, confirmation_handler);
        }
        Jid expected_occupant = conversation.counterpart.with_resource(
            "visitor");
        Xmpp.Xep.Muc.Flag muc_flag = stream.get_flag<Xmpp.Xep.Muc.Flag>(
            Xmpp.Xep.Muc.Flag.IDENTITY);
        if (confirmations != 1 || confirmed_occupant == null ||
                !((!) confirmed_occupant).equals(expected_occupant) ||
                confirmed_role != Xmpp.Xep.Muc.Role.PARTICIPANT ||
                stream.admin_set_roles.size != 1 ||
                stream.admin_set_roles[0] != "participant" ||
                stream.occupant_presence_resync_count != 0 ||
                muc_flag.get_occupant_role(expected_occupant) !=
                    Xmpp.Xep.Muc.Role.PARTICIPANT) {
            throw new IOError.FAILED(
                "confirmed unmute must signal once, avoid replay, and accept the server's participant Presence");
        }
    }

    private void test_confirmed_affiliation_change_waits_for_presence_without_replay() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream.negotiation_complete = true;
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, stream);
            establish_owner_context(stream, account, conversation);
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "member", account.full_jid,
                "member", "participant"));

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_confirmed_affiliation_change_without_replay.begin(muc_manager,
                account, conversation, stream, (obj, res) => {
                    try {
                        run_confirmed_affiliation_change_without_replay.end(res);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "confirmed affiliation Presence audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_confirmed_affiliation_change_without_replay(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        yield muc_manager.set_affiliation_checked(account,
            conversation.counterpart, new Jid("member@example.test"),
            "admin", "promote member");
        if (stream.occupant_presence_resync_count != 0) {
            throw new IOError.FAILED(
                "a confirmed affiliation IQ must not request an extra occupant replay");
        }
        stream.emit_presence(build_occupant_presence(
            conversation.counterpart, "member", account.full_jid,
            "admin", "participant"));
        Jid expected_occupant = conversation.counterpart.with_resource(
            "member");
        Xmpp.Xep.Muc.Flag muc_flag = stream.get_flag<Xmpp.Xep.Muc.Flag>(
            Xmpp.Xep.Muc.Flag.IDENTITY);
        if (stream.admin_set_affiliations.size != 1 ||
                stream.admin_set_affiliations[0] != "admin" ||
                stream.occupant_presence_resync_count != 0 ||
                muc_flag.get_affiliation(conversation.counterpart,
                    expected_occupant) != Xmpp.Xep.Muc.Affiliation.ADMIN) {
            throw new IOError.FAILED(
                "confirmed affiliation IQ must avoid replay and accept the server's live Admin Presence");
        }
    }

    private static bool stream_has_presence_occupant(
            MucManagerAuditStream stream, Jid room, string nick) {
        Gee.List<Jid>? resources = stream.get_flag<Xmpp.Presence.Flag>(
            Xmpp.Presence.Flag.IDENTITY).get_resources(room);
        if (resources == null) return false;
        foreach (Jid occupant in (!) resources) {
            if (occupant.resourcepart == nick) return true;
        }
        return false;
    }

    private void test_timed_ban_restores_known_none_and_clears_persistence() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account, stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_timed_ban_restore.begin(muc_manager, stream_interactor, account,
                conversation, stream, (obj, res) => {
                    try {
                        run_timed_ban_restore.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(6, () => {
                failure = "timed out waiting for timed-ban restoration";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_timed_ban_restore(MucManager muc_manager,
            StreamInteractor stream_interactor, Account account,
            Conversation conversation, MucManagerAuditStream stream) throws Error {
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(joined, "timed-ban test join");
        establish_owner_context(stream, account, conversation);

        stream.emit_presence(build_occupant_presence(conversation.counterpart,
            "bob", account.full_jid, "none", "participant"));
        Jid target = new Jid("bob@example.test");
        int before_admin_iqs = stream.admin_iq_count;

        yield muc_manager.ban_for_seconds_for_tests(account,
            conversation.counterpart, target, 1);
        if (!muc_manager.has_pending_timed_ban_for_tests(account,
                conversation.counterpart, target)) {
            throw new IOError.FAILED("successful timed ban must register one pending restoration");
        }
        Database db = ((MucManagerTestApplication) GLib.Application.get_default()).db;
        string? persisted = db.account_settings.get_value(account.id,
            "muc-timed-bans-v1");
        if (persisted == null || !((!) persisted).contains(target.to_string())) {
            throw new IOError.FAILED("pending timed ban must be persisted in the encrypted profile database");
        }

        var waited = new Gee.Promise<bool>();
        Timeout.add_seconds(3, () => {
            waited.set_value(true);
            return Source.REMOVE;
        });
        try {
            yield waited.future.wait_async();
        } catch (Gee.FutureError e) {
            throw new IOError.FAILED("timed-ban wait failed: %s".printf(e.message));
        }

        if (muc_manager.has_pending_timed_ban_for_tests(account,
                conversation.counterpart, target)) {
            throw new IOError.FAILED("expired timed ban must clear its pending restoration");
        }
        if (stream.admin_iq_count != before_admin_iqs + 2) {
            throw new IOError.FAILED("timed ban must send exactly one outcast and one restore IQ");
        }
        if (stream.admin_set_affiliations.size < 2 ||
                stream.admin_set_affiliations[stream.admin_set_affiliations.size - 2] != "outcast" ||
                stream.admin_set_affiliations[stream.admin_set_affiliations.size - 1] != "none") {
            throw new IOError.FAILED("timed ban must restore the authoritative pre-ban none affiliation");
        }
        if (db.account_settings.get_value(account.id, "muc-timed-bans-v1") != null) {
            throw new IOError.FAILED("completed timed ban must remove its persisted restoration record");
        }
    }

    private void test_timed_ban_unknown_after_reconnect_retries_without_iq() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            var replacement = new MucManagerAuditStream(
                new Jid("replacement.example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_timed_ban_unknown_after_reconnect.begin(muc_manager,
                stream_interactor, account, conversation, stream,
                replacement, (obj, res) => {
                    try {
                        run_timed_ban_unknown_after_reconnect.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out waiting for unknown timed-ban audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_timed_ban_unknown_after_reconnect(
            MucManager muc_manager, StreamInteractor stream_interactor,
            Account account, Conversation conversation,
            MucManagerAuditStream stream,
            MucManagerAuditStream replacement) throws Error {
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(joined, "unknown timed-ban test join");
        establish_owner_context(stream, account, conversation);
        Jid target = new Jid("bob@example.test");
        stream.emit_presence(build_occupant_presence(
            conversation.counterpart, "bob", account.full_jid, "none",
            "participant", target.with_resource("device")));

        yield muc_manager.ban_for_seconds_for_tests(account,
            conversation.counterpart, target, 60);
        if (stream.admin_set_count != 1) {
            throw new IOError.FAILED(
                "timed-ban setup must send exactly one outcast IQ");
        }
        // Replace the shared account modules only after the original
        // connection has completed the initial join and confirmed ban IQ.
        attach_muc_stream_modules_for_tests(stream_interactor, account,
            replacement);
        stream_interactor.connection_manager.set_connected_stream_for_tests(
            account, replacement);

        GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
            "*Cannot verify expired timed MUC ban*without changing affiliation*");
        yield muc_manager.expire_timed_ban_for_tests(account,
            conversation.counterpart, target);
        GLib.Test.assert_expected_messages();

        if (!muc_manager.has_pending_timed_ban_for_tests(account,
                conversation.counterpart, target) ||
                muc_manager.timed_ban_retry_count_for_tests(account,
                    conversation.counterpart, target) != 1) {
            throw new IOError.FAILED(
                "unknown current affiliation must preserve and retry the timed ban");
        }
        if (stream.admin_set_count != 1 ||
                replacement.admin_set_count != 0) {
            throw new IOError.FAILED(
                "unknown current affiliation must send no restoration IQ");
        }
        Database db = ((MucManagerTestApplication)
            GLib.Application.get_default()).db;
        string? persisted = db.account_settings.get_value(account.id,
            "muc-timed-bans-v1");
        if (persisted == null || !((!) persisted).contains(
                target.to_string())) {
            throw new IOError.FAILED(
                "deferred timed-ban restoration must remain persisted");
        }
        stream_interactor.account_removed(account);
    }

    private void test_private_muc_conversation_identity() {
        with_active_muc((stream_interactor, account, conversation) => {
            ConversationManager conversation_manager = (!)
                stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);
            Jid first_occupant = conversation.counterpart.bare_jid.with_resource("first");
            Jid second_occupant = conversation.counterpart.bare_jid.with_resource("second");

            int activated_count = 0;
            ulong activated_handler = conversation_manager.conversation_activated.connect((activated) => {
                if (activated.type_ == Conversation.Type.GROUPCHAT_PM) activated_count++;
            });

            Conversation first_pm = conversation_manager.create_conversation(
                first_occupant, account, Conversation.Type.GROUPCHAT_PM);
            Conversation second_pm = conversation_manager.create_conversation(
                second_occupant, account, Conversation.Type.GROUPCHAT_PM);
            conversation_manager.start_conversation(first_pm);
            conversation_manager.start_conversation(second_pm);

            fail_if(first_pm.id <= 0 || second_pm.id <= 0,
                "private MUC conversations must receive persisted database ids");
            fail_if(first_pm.id == second_pm.id,
                "different MUC occupants must not share a conversation id");
            fail_if(!first_pm.counterpart.equals(first_occupant) ||
                    !second_pm.counterpart.equals(second_occupant),
                "private MUC conversation identity must retain the full occupant JID");
            fail_if(first_pm.encryption != Encryption.NONE || second_pm.encryption != Encryption.NONE,
                "private MUC conversations must remain unencrypted");
            fail_if(activated_count != 2,
                "starting two private MUC conversations must activate both exactly once");

            MessageProcessor message_processor = (!)
                stream_interactor.get_module<MessageProcessor>(
                    MessageProcessor.IDENTITY);
            Message first_message = message_processor.create_out_message(
                "first private thread", first_pm);
            first_message.time = new DateTime.now_utc().add_seconds(-10);
            Message second_message = message_processor.create_out_message(
                "second private thread", second_pm);
            second_message.time = new DateTime.now_utc();
            MessageStorage message_storage = (!)
                stream_interactor.get_module<MessageStorage>(
                    MessageStorage.IDENTITY);
            fail_if(message_storage.get_last_message(first_pm) != first_message,
                "a private MUC thread must not read the last message from another nickname");
            fail_if(message_storage.get_last_message(second_pm) != second_message,
                "each private MUC nickname must retain its own last message");

            Gee.List<Conversation> active = conversation_manager.get_active_conversations(account);
            fail_if(!active.contains(first_pm) || !active.contains(second_pm),
                "both private MUC conversations must remain visible in the active list");

            Gee.List<Conversation> persisted = ((MucManagerTestApplication)
                GLib.Application.get_default()).db.get_conversations(account);
            bool found_first = false;
            bool found_second = false;
            foreach (Conversation stored in persisted) {
                if (stored.type_ != Conversation.Type.GROUPCHAT_PM) continue;
                if (stored.counterpart.equals(first_occupant)) found_first = true;
                if (stored.counterpart.equals(second_occupant)) found_second = true;
            }
            fail_if(!found_first || !found_second,
                "both private MUC occupant identities must survive database reload");

            // Clearing room/first must never erase room/second merely because
            // both PMs share the same bare room JID and message type.
            conversation_manager.clear_conversation_history(first_pm);
            Database db = ((MucManagerTestApplication)
                GLib.Application.get_default()).db;
            fail_if(db.message.select()
                    .with(db.message.account_id, "=", account.id)
                    .with(db.message.counterpart_id, "=",
                        db.get_jid_id(first_occupant))
                    .with(db.message.counterpart_resource, "=", "first")
                    .with(db.message.type_, "=", Message.Type.GROUPCHAT_PM)
                    .count() != 0,
                "clearing one private MUC nickname must delete that thread");
            fail_if(db.message.select()
                    .with(db.message.account_id, "=", account.id)
                    .with(db.message.counterpart_id, "=",
                        db.get_jid_id(second_occupant))
                    .with(db.message.counterpart_resource, "=", "second")
                    .with(db.message.type_, "=", Message.Type.GROUPCHAT_PM)
                    .count() != 1,
                "clearing one private MUC nickname must preserve sibling threads");
            fail_if(message_storage.get_last_message(second_pm) != second_message,
                "clearing another private MUC nickname must preserve its cached history");

            SignalHandler.disconnect(conversation_manager, activated_handler);
        });
    }

    private void test_private_muc_reply_reuses_exact_full_jid_conversation() {
        with_active_muc((stream_interactor, account, room_conversation) => {
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                room_conversation.counterpart, room_conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, room_conversation);

            Jid occupant = room_conversation.counterpart.with_resource("bob");
            stream.emit_presence(build_occupant_presence(
                room_conversation.counterpart, "bob", account.full_jid,
                "member", "participant",
                new Jid("bob@example.test/device")));

            ConversationManager conversation_manager = (!)
                stream_interactor.get_module<ConversationManager>(
                    ConversationManager.IDENTITY);
            Conversation stale_bare_chat = conversation_manager.create_conversation(
                room_conversation.counterpart, account, Conversation.Type.CHAT);
            stale_bare_chat.encryption = Encryption.OMEMO;
            Conversation private_conversation = conversation_manager.create_conversation(
                occupant, account, Conversation.Type.GROUPCHAT_PM);

            fail_if(stale_bare_chat.encryption != Encryption.OMEMO,
                "the regression setup needs the stale bare-room CHAT to use default OMEMO");
            fail_if(private_conversation.encryption != Encryption.NONE,
                "the exact full-JID MUC PM setup must remain unencrypted");

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_private_muc_reply_routing_audit.begin(stream_interactor,
                account, occupant, stale_bare_chat, private_conversation,
                (obj, res) => {
                    try {
                        run_private_muc_reply_routing_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out while classifying an incoming MUC PM reply";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);

            fail_if(failure != null,
                "incoming MUC PM routing audit failed: %s".printf(
                    failure ?? "unknown error"));
        });
    }

    private async void run_private_muc_reply_routing_audit(
            StreamInteractor stream_interactor, Account account, Jid occupant,
            Conversation stale_bare_chat, Conversation private_conversation)
            throws Error {
        StanzaNode incoming_node = new StanzaNode.build("message")
            .put_attribute("from", occupant.to_string())
            .put_attribute("to", account.full_jid.to_string())
            .put_attribute("type", Xmpp.MessageStanza.TYPE_CHAT)
            .put_attribute("id", "incoming-muc-pm-reply")
            .put_node(new StanzaNode.build("body").put_node(
                new StanzaNode.text("private reply")))
            .put_node(new StanzaNode.build("x", NS_MUC_USER)
                .add_self_xmlns());
        var incoming_stanza = new Xmpp.MessageStanza.from_stanza(incoming_node,
            account.full_jid);
        MessageProcessor processor = (!)
            stream_interactor.get_module<MessageProcessor>(
                MessageProcessor.IDENTITY);
        Message parsed = yield processor.parse_message_stanza(account,
            incoming_stanza);

        if (parsed.type_ != Message.Type.GROUPCHAT_PM) {
            throw new IOError.FAILED(
                "incoming room/nick reply was classified as %d instead of GROUPCHAT_PM"
                    .printf((int) parsed.type_));
        }
        if (!parsed.counterpart.equals(occupant)) {
            throw new IOError.FAILED(
                "incoming MUC PM reply lost its full room/nick counterpart");
        }

        ConversationManager conversation_manager = (!)
            stream_interactor.get_module<ConversationManager>(
                ConversationManager.IDENTITY);
        Conversation? resolved = conversation_manager.get_conversation_for_message(
            parsed);
        if (resolved == null || (!) resolved != private_conversation ||
                ((!) resolved).id != private_conversation.id) {
            throw new IOError.FAILED(
                "incoming MUC PM reply did not reuse the exact outgoing thread");
        }
        if ((!) resolved == stale_bare_chat ||
                ((!) resolved).encryption != Encryption.NONE) {
            throw new IOError.FAILED(
                "incoming MUC PM reply was routed into the stale OMEMO room chat");
        }
    }

    private void test_private_muc_join_hydrates_and_rehydrates_affiliation_snapshot() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname,
                null, null, "owner");
            stream.disco_members_only = true;
            stream.disco_non_anonymous = true;
            Jid bob = new Jid("bob@example.test");
            Jid carol = new Jid("carol@example.test");
            Jid dave = new Jid("dave@example.test");
            stream.set_server_affiliation_for_tests(account.bare_jid,
                "owner");
            stream.set_server_affiliation_for_tests(bob, "member");
            stream.set_server_affiliation_for_tests(carol, "admin");

            var queries = new Gee.ArrayList<string>();
            ulong query_handler = stream.affiliation_query_received.connect(
                (affiliation) => queries.add(affiliation));
            bool joined_signal_seen = false;
            bool joined_state_visible = true;
            ulong joined_handler = muc_manager.joined.connect(
                (joined_account, joined_room) => {
                    if (!joined_account.equals(account) ||
                            !joined_room.equals_bare(
                                conversation.counterpart)) return;
                    joined_signal_seen = true;
                    joined_state_visible = joined_state_visible &&
                        muc_manager.is_joined(joined_room, joined_account);
                });
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_private_muc_join_snapshot_rehydration.begin(muc_manager,
                account, conversation, stream, bob, carol, dave, queries,
                (obj, res) => {
                    try {
                        run_private_muc_join_snapshot_rehydration.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = 0;
            timeout_id = Timeout.add_seconds(8, () => {
                failure = "private MUC join snapshot hydration timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            SignalHandler.disconnect(stream, query_handler);
            SignalHandler.disconnect(muc_manager, joined_handler);
            if (!joined_signal_seen || !joined_state_visible) {
                failure = "joined observers must synchronously see the committed joined state";
            }
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_private_muc_join_snapshot_rehydration(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream, Jid bob, Jid carol, Jid dave,
            Gee.ArrayList<string> queries) throws Error {
        int snapshot_change_events = 0;
        uint last_snapshot_revision = 0;
        ulong snapshot_handler =
            muc_manager.private_muc_affiliation_snapshot_changed.connect(
                (changed_account, changed_room, revision) => {
                    if (changed_account.equals(account) &&
                            changed_room.equals_bare(
                                conversation.counterpart)) {
                        snapshot_change_events++;
                        last_snapshot_revision = revision;
                    }
                });
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(joined, "private MUC hydration join");
        for (int i = 0; i < 50 &&
                !muc_manager.has_complete_private_muc_affiliation_snapshot(
                    account, conversation.counterpart); i++) {
            yield wait_muc_audit_tick();
        }
        assert_private_muc_snapshot(muc_manager, account,
            conversation.counterpart, { account.bare_jid, bob, carol },
            "initial private MUC join");
        assert_affiliation_query_sequence(queries,
            { "member", "admin", "owner" },
            "initial private MUC join");
        if (stream.admin_iq_count != 3) {
            throw new IOError.FAILED(
                "initial private MUC join must issue exactly three affiliation IQs, got %d"
                    .printf(stream.admin_iq_count));
        }

        uint initial_revision = muc_manager
            .get_private_muc_affiliation_snapshot_revision(account,
                conversation.counterpart);
        int initial_change_events = snapshot_change_events;
        Jid erin = new Jid("erin@example.test");
        stream.emit_presence(build_occupant_presence(
            conversation.counterpart, "erin", account.full_jid, "member",
            "participant", erin));
        for (int i = 0; i < 30 &&
                muc_manager.get_private_muc_affiliation_snapshot_revision(
                    account, conversation.counterpart) == initial_revision;
                i++) {
            yield wait_muc_audit_tick();
        }
        assert_private_muc_snapshot(muc_manager, account,
            conversation.counterpart,
            { account.bare_jid, bob, carol, erin },
            "private MUC live membership delta");
        if (snapshot_change_events != initial_change_events + 1 ||
                last_snapshot_revision != initial_revision + 1) {
            throw new IOError.FAILED(
                "one authoritative member delta must publish exactly one new snapshot revision");
        }
        stream.emit_presence(build_occupant_presence(
            conversation.counterpart, "erin", account.full_jid, "member",
            "participant", erin));
        for (int i = 0; i < 4; i++) yield wait_muc_audit_tick();
        if (snapshot_change_events != initial_change_events + 1 ||
                muc_manager.get_private_muc_affiliation_snapshot_revision(
                    account, conversation.counterpart) !=
                    initial_revision + 1) {
            throw new IOError.FAILED(
                "routine presence for an unchanged member set must not retrigger OMEMO readiness");
        }

        stream.set_server_affiliation_for_tests(bob, "none");
        stream.set_server_affiliation_for_tests(dave, "member");
        Xmpp.Xep.Muc.JoinResult? rejoined = yield
            muc_manager.force_rejoin_for_tests(account,
                conversation.counterpart, conversation.nickname);
        validate_join_result(rejoined, "private MUC hydration rejoin");
        for (int i = 0; i < 50 &&
                !muc_manager.has_complete_private_muc_affiliation_snapshot(
                    account, conversation.counterpart); i++) {
            yield wait_muc_audit_tick();
        }
        assert_private_muc_snapshot(muc_manager, account,
            conversation.counterpart, { account.bare_jid, carol, dave },
            "private MUC rejoin");
        Gee.List<Jid>? refreshed =
            muc_manager.get_private_muc_member_affiliation_snapshot(account,
                conversation.counterpart);
        if (refreshed == null || jid_list_contains_bare((!) refreshed, bob)) {
            throw new IOError.FAILED(
                "private MUC rejoin must discard the previous member list");
        }
        assert_affiliation_query_sequence(queries,
            { "member", "admin", "owner", "member", "admin", "owner" },
            "private MUC rejoin");
        if (stream.admin_iq_count != 6) {
            throw new IOError.FAILED(
                "private MUC rejoin must issue one fresh three-IQ snapshot, got %d total"
                    .printf(stream.admin_iq_count));
        }
        SignalHandler.disconnect(muc_manager, snapshot_handler);
    }

    private void test_private_muc_join_affiliation_failure_stays_incomplete() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname,
                null, null, "owner");
            stream.disco_members_only = true;
            stream.disco_non_anonymous = true;
            stream.fail_query_affiliation = "admin";
            stream.set_server_affiliation_for_tests(account.bare_jid,
                "owner");
            stream.set_server_affiliation_for_tests(
                new Jid("bob@example.test"), "member");
            var queries = new Gee.ArrayList<string>();
            ulong query_handler = stream.affiliation_query_received.connect(
                (affiliation) => queries.add(affiliation));
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_private_muc_join_snapshot_failure.begin(muc_manager, account,
                conversation, stream, queries, (obj, res) => {
                    try {
                        run_private_muc_join_snapshot_failure.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(8, () => {
                failure = "private MUC failed-snapshot audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            SignalHandler.disconnect(stream, query_handler);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private void test_private_muc_early_readiness_keeps_enter_room_info_owner() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname,
                null, null, "owner");
            stream.disco_members_only = true;
            stream.disco_non_anonymous = true;
            stream.defer_disco_info = true;
            stream.set_server_affiliation_for_tests(account.bare_jid,
                "owner");
            stream.set_server_affiliation_for_tests(
                new Jid("bob@example.test"), "member");
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            bool timed_out = false;
            run_private_muc_early_readiness_audit.begin(muc_manager, account,
                conversation, stream, (obj, res) => {
                    try {
                        run_private_muc_early_readiness_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(8, () => {
                timed_out = true;
                failure = "private MUC early readiness audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (!timed_out) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_private_muc_early_readiness_audit(
            MucManager muc_manager, Account account,
            Conversation conversation, MucManagerAuditStream stream)
            throws Error {
        Xmpp.Xep.Muc.Module muc_module = stream.get_module<
            Xmpp.Xep.Muc.Module>(Xmpp.Xep.Muc.Module.IDENTITY);
        int room_info_query_count = 0;
        ulong query_started_handler = muc_module.room_info_query_started.connect(
            (query_stream, query_room) => {
                if (query_stream == stream && query_room.equals_bare(
                        conversation.counterpart)) room_info_query_count++;
            });
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(joined, "private MUC held-room-info join");
        int initial_disco_count = stream.disco_iq_count;
        if (room_info_query_count != 1 || stream.held_disco_count < 1 ||
                !muc_manager.has_pending_muc_room_info(account,
                    conversation.counterpart)) {
            throw new IOError.FAILED(
                "enter() must retain exactly one pending room-info request after join (room-info=%d disco=%d held=%d pending=%s)"
                    .printf(room_info_query_count, stream.disco_iq_count,
                        stream.held_disco_count,
                        muc_manager.has_pending_muc_room_info(account,
                            conversation.counterpart).to_string()));
        }

        Gee.List<Jid>? early = yield
            muc_manager.query_private_muc_affiliation_snapshot(account,
                conversation.counterpart);
        if (early != null || room_info_query_count != 1 ||
                stream.disco_iq_count != initial_disco_count) {
            throw new IOError.FAILED(
                "early OMEMO readiness must not supersede enter() with a second disco request");
        }

        stream.release_held_disco_successes();
        for (int i = 0; i < 50 &&
                !muc_manager.has_complete_private_muc_affiliation_snapshot(
                    account, conversation.counterpart); i++) {
            yield wait_muc_audit_tick();
        }
        if (stream.disco_iq_count != initial_disco_count ||
                room_info_query_count != 1 || stream.admin_iq_count != 3 ||
                muc_manager.get_private_muc_affiliation_snapshot_revision(
                    account, conversation.counterpart) != 1) {
            throw new IOError.FAILED(
                "the original room-info completion must establish one snapshot and one revision");
        }

        uint revision = muc_manager
            .get_private_muc_affiliation_snapshot_revision(account,
                conversation.counterpart);
        Gee.List<Jid>? ready = yield
            muc_manager.query_private_muc_affiliation_snapshot(account,
                conversation.counterpart);
        if (ready == null || ((!) ready).size != 2 ||
                muc_manager.get_private_muc_affiliation_snapshot_revision(
                    account, conversation.counterpart) != revision ||
                stream.disco_iq_count != initial_disco_count ||
                room_info_query_count != 1 || stream.admin_iq_count != 3) {
            throw new IOError.FAILED(
                "passive consumers must reuse the completed initial snapshot without changing its revision");
        }
        SignalHandler.disconnect(muc_module, query_started_handler);
    }

    private void test_private_muc_incoming_encryption_waits_for_enter_room_info() {
        with_active_muc((stream_interactor, account, conversation) => {
            Database db = ((MucManagerTestApplication)
                GLib.Application.get_default()).db;
            var settings = new Dino.Entities.Settings.from_db(db);
            settings.set_default_encryption(account, Encryption.OMEMO);

            MucManager muc_manager = stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname,
                null, null, "owner");
            stream.disco_members_only = true;
            stream.disco_non_anonymous = true;
            stream.defer_disco_info = true;
            stream.set_server_affiliation_for_tests(account.bare_jid,
                "owner");
            stream.set_server_affiliation_for_tests(
                new Jid("bob@example.test"), "member");
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            bool timed_out = false;
            run_private_muc_incoming_encryption_wait_audit.begin(
                stream_interactor, muc_manager, account, conversation, stream,
                (obj, result) => {
                    try {
                        run_private_muc_incoming_encryption_wait_audit.end(
                            result);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(8, () => {
                timed_out = true;
                failure = "private MUC incoming encryption wait audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (!timed_out) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private void test_private_muc_displayed_markers_track_verified_readers() {
        with_active_muc((stream_interactor, account, conversation) => {
            Database db = ((MucManagerTestApplication)
                GLib.Application.get_default()).db;
            MucManager muc_manager = stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname,
                null, null, "owner");
            stream.disco_members_only = true;
            stream.disco_non_anonymous = true;
            stream.set_server_affiliation_for_tests(account.bare_jid,
                "owner");
            stream.set_server_affiliation_for_tests(
                new Jid("bob@example.test"), "member");
            stream.set_server_affiliation_for_tests(
                new Jid("carol@example.test"), "member");
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            bool timed_out = false;
            run_private_muc_displayed_marker_audit.begin(stream_interactor,
                db, muc_manager, account, conversation, stream, (obj, res) => {
                    try {
                        run_private_muc_displayed_marker_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(8, () => {
                timed_out = true;
                failure = "private MUC displayed-marker audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (!timed_out) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_private_muc_displayed_marker_audit(
            StreamInteractor stream_interactor, Database db,
            MucManager muc_manager, Account account,
            Conversation conversation, MucManagerAuditStream stream)
            throws Error {
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(joined, "private MUC displayed-marker join");
        for (int i = 0; i < 40 &&
                !muc_manager.has_live_private_room_features(account,
                    conversation.counterpart); i++) {
            yield wait_muc_audit_tick();
        }
        if (!muc_manager.has_live_private_room_features(account,
                conversation.counterpart)) {
            throw new IOError.FAILED(
                "displayed-marker audit did not establish private room features");
        }

        Jid bob_occupant = conversation.counterpart.with_resource("bob");
        Jid carol_occupant = conversation.counterpart.with_resource("carol");
        stream.emit_presence(build_occupant_presence(
            conversation.counterpart, "bob", account.full_jid,
            "member", "participant",
            new Jid("bob@example.test/phone")));
        stream.emit_presence(build_occupant_presence(
            conversation.counterpart, "carol", account.full_jid,
            "member", "participant",
            new Jid("carol@example.test/laptop")));

        MessageStorage storage = stream_interactor.get_module<MessageStorage>(
            MessageStorage.IDENTITY);
        Message older = new Message("older room message") {
            account = account,
            counterpart = conversation.counterpart,
            ourpart = account.full_jid,
            direction = Message.DIRECTION_SENT,
            type_ = Message.Type.GROUPCHAT,
            time = new DateTime.from_unix_utc(100),
            local_time = new DateTime.from_unix_utc(100),
            marked = Message.Marked.RECEIVED
        };
        older.set_stable_reference("room-stanza-older",
            conversation.counterpart.bare_jid);
        storage.add_message(older, conversation);

        Message newer = new Message("newer room message") {
            account = account,
            counterpart = conversation.counterpart,
            ourpart = account.full_jid,
            direction = Message.DIRECTION_SENT,
            type_ = Message.Type.GROUPCHAT,
            time = new DateTime.from_unix_utc(101),
            local_time = new DateTime.from_unix_utc(101),
            marked = Message.Marked.RECEIVED
        };
        newer.set_stable_reference("room-stanza-newer",
            conversation.counterpart.bare_jid);
        storage.add_message(newer, conversation);

        var displayed = new DisplayedStateManager.for_tests(
            stream_interactor, new Dino.Entities.Settings.from_db(db), db);
        if (displayed.apply_contact_marker_for_tests(conversation,
                    bob_occupant, "room-stanza-older") !=
                DisplayedMarkerApplyResult.APPLIED ||
                displayed.get_groupchat_reader_count(conversation, older) != 1) {
            throw new IOError.FAILED(
                "a verified private-MUC reader must advance its own pointer");
        }
        if (displayed.apply_contact_marker_for_tests(conversation,
                    carol_occupant, "room-stanza-newer") !=
                DisplayedMarkerApplyResult.APPLIED ||
                displayed.get_groupchat_reader_count(conversation, older) != 2 ||
                displayed.get_groupchat_reader_count(conversation, newer) != 1) {
            throw new IOError.FAILED(
                "private-MUC participants must retain independent pointers");
        }
        if (older.marked == Message.Marked.READ ||
                newer.marked == Message.Marked.READ) {
            throw new IOError.FAILED(
                "one participant marker must not mark a room message globally read");
        }

        if (displayed.apply_contact_marker_for_tests(conversation,
                    conversation.counterpart.with_resource("unknown"),
                    "room-stanza-older") !=
                DisplayedMarkerApplyResult.REJECTED ||
                displayed.get_groupchat_reader_count(conversation, older) != 2) {
            throw new IOError.FAILED(
                "an unverified nick-only marker must fail closed");
        }

        Message wrong_authority = new Message("wrong authority") {
            account = account,
            counterpart = conversation.counterpart,
            ourpart = account.full_jid,
            direction = Message.DIRECTION_SENT,
            type_ = Message.Type.GROUPCHAT,
            time = new DateTime.from_unix_utc(102),
            local_time = new DateTime.from_unix_utc(102)
        };
        wrong_authority.set_stable_reference("wrong-authority-id",
            new Jid("other@conference.example.test"));
        storage.add_message(wrong_authority, conversation);
        if (displayed.apply_contact_marker_for_tests(conversation,
                    bob_occupant, "wrong-authority-id") !=
                DisplayedMarkerApplyResult.REJECTED) {
            throw new IOError.FAILED(
                "a marker with the wrong XEP-0359 authority must not resolve");
        }
    }

    private async void run_private_muc_incoming_encryption_wait_audit(
            StreamInteractor stream_interactor, MucManager muc_manager,
            Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        Xmpp.Xep.Muc.Module muc_module = stream.get_module<
            Xmpp.Xep.Muc.Module>(Xmpp.Xep.Muc.Module.IDENTITY);
        int room_info_query_count = 0;
        ulong query_started_handler = muc_module.room_info_query_started.connect(
            (query_stream, query_room) => {
                if (query_stream == stream && query_room.equals_bare(
                        conversation.counterpart)) room_info_query_count++;
            });
        try {
            Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
                conversation.counterpart, conversation.nickname, null, true);
            validate_join_result(joined,
                "private MUC incoming-encryption held-room-info join");
            if (conversation.encryption != Encryption.NONE ||
                    room_info_query_count != 1 ||
                    !muc_manager.has_pending_muc_room_info(account,
                        conversation.counterpart)) {
                throw new IOError.FAILED(
                    "the joined conversation must remain NONE while its single room-info query is pending");
            }
            int initial_disco_count = stream.disco_iq_count;

            var encrypted = new Entities.Message("private history");
            encrypted.account = account;
            encrypted.counterpart = conversation.counterpart;
            encrypted.type_ = Entities.Message.Type.GROUPCHAT;
            encrypted.direction = Entities.Message.DIRECTION_RECEIVED;
            encrypted.encryption = Encryption.OMEMO;

            bool completed = false;
            bool accepted = false;
            MessageProcessor processor = stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY);
            processor.reconcile_pending_groupchat_encryption.begin(encrypted,
                conversation, (obj, result) => {
                    accepted = processor
                        .reconcile_pending_groupchat_encryption.end(result);
                    completed = true;
                });
            yield wait_muc_audit_tick();
            if (completed || room_info_query_count != 1 ||
                    stream.disco_iq_count != initial_disco_count) {
                throw new IOError.FAILED(
                    "the incoming message must join the existing room-info flight without starting another disco query");
            }

            stream.release_held_disco_successes();
            for (int i = 0; i < 50 && !completed; i++) {
                yield wait_muc_audit_tick();
            }
            if (!completed || !accepted ||
                    conversation.encryption != Encryption.OMEMO ||
                    room_info_query_count != 1 ||
                    stream.disco_iq_count != initial_disco_count) {
                throw new IOError.FAILED(
                    "authoritative private room info must resume the encrypted message under the restored OMEMO mode");
            }
        } finally {
            SignalHandler.disconnect(muc_module, query_started_handler);
        }
    }

    private void test_private_muc_room_info_failure_settles_pending_readiness() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname,
                null, null, "owner");
            stream.defer_disco_info = true;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            bool timed_out = false;
            run_private_muc_room_info_failure_audit.begin(muc_manager,
                account, conversation, stream, (obj, res) => {
                    try {
                        run_private_muc_room_info_failure_audit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(8, () => {
                timed_out = true;
                failure = "private MUC failed room-info audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (!timed_out) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_private_muc_room_info_failure_audit(
            MucManager muc_manager, Account account,
            Conversation conversation, MucManagerAuditStream stream)
            throws Error {
        int failed_signals = 0;
        Xmpp.Xep.Muc.Module muc_module = stream.get_module<
            Xmpp.Xep.Muc.Module>(Xmpp.Xep.Muc.Module.IDENTITY);
        int room_info_query_count = 0;
        ulong query_started_handler = muc_module.room_info_query_started.connect(
            (query_stream, query_room) => {
                if (query_stream == stream && query_room.equals_bare(
                        conversation.counterpart)) room_info_query_count++;
            });
        ulong failed_handler = muc_manager.room_info_query_failed.connect(
            (failed_account, failed_room) => {
                if (failed_account.equals(account) &&
                        failed_room.equals_bare(conversation.counterpart)) {
                    failed_signals++;
                }
            });
        try {
            Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
                conversation.counterpart, conversation.nickname, null, true);
            validate_join_result(joined, "private MUC failed-room-info join");
            int initial_disco_count = stream.disco_iq_count;
            if (room_info_query_count != 1 || stream.held_disco_count < 1 ||
                    !muc_manager.has_pending_muc_room_info(account,
                        conversation.counterpart)) {
                throw new IOError.FAILED(
                    "join must expose exactly one pending room-info request before failure (room-info=%d disco=%d held=%d pending=%s)"
                        .printf(room_info_query_count,
                            stream.disco_iq_count, stream.held_disco_count,
                            muc_manager.has_pending_muc_room_info(account,
                                conversation.counterpart).to_string()));
            }

            Gee.List<Jid>? pending = yield
                muc_manager.query_private_muc_affiliation_snapshot(account,
                    conversation.counterpart);
            if (pending != null || room_info_query_count != 1 ||
                    stream.disco_iq_count != initial_disco_count) {
                throw new IOError.FAILED(
                    "pending readiness must not start a second room-info request");
            }

            bool wait_completed = false;
            bool wait_result = true;
            muc_manager.wait_for_pending_muc_room_info.begin(account,
                conversation.counterpart, (obj, result) => {
                    wait_result = muc_manager
                        .wait_for_pending_muc_room_info.end(result);
                    wait_completed = true;
                });
            yield wait_muc_audit_tick();
            if (wait_completed || room_info_query_count != 1 ||
                    stream.disco_iq_count != initial_disco_count) {
                throw new IOError.FAILED(
                    "a room-info consumer must wait on the existing failed-flight candidate without duplicating disco");
            }

            stream.release_held_disco_errors(
                Xmpp.ErrorStanza.CONDITION_SERVICE_UNAVAILABLE);
            for (int i = 0; i < 30 &&
                    (failed_signals == 0 || !wait_completed); i++) {
                yield wait_muc_audit_tick();
            }
            if (failed_signals != 1 ||
                    !wait_completed || wait_result ||
                    muc_manager.has_pending_muc_room_info(account,
                        conversation.counterpart) ||
                    !muc_manager.has_failed_muc_room_info(account,
                        conversation.counterpart)) {
                throw new IOError.FAILED(
                    "the current room-info failure must settle pending state and publish one terminal failure");
            }

            Gee.List<Jid>? settled = yield
                muc_manager.query_private_muc_affiliation_snapshot(account,
                    conversation.counterpart);
            if (settled != null ||
                    stream.disco_iq_count != initial_disco_count ||
                    room_info_query_count != 1 || failed_signals != 1) {
                throw new IOError.FAILED(
                    "a terminal automatic readiness recheck must not loop room-info requests");
            }
        } finally {
            SignalHandler.disconnect(muc_manager, failed_handler);
            SignalHandler.disconnect(muc_module, query_started_handler);
        }
    }

    private async void run_private_muc_join_snapshot_failure(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream, Gee.ArrayList<string> queries)
            throws Error {
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(joined, "private MUC failed-snapshot join");
        for (int i = 0; i < 20 && stream.admin_iq_count < 3; i++) {
            yield wait_muc_audit_tick();
        }
        for (int i = 0; i < 4; i++) yield wait_muc_audit_tick();
        if (muc_manager.has_complete_private_muc_affiliation_snapshot(account,
                conversation.counterpart) ||
                muc_manager.get_private_muc_member_affiliation_snapshot(
                    account, conversation.counterpart) != null) {
            throw new IOError.FAILED(
                "a forbidden affiliation list must keep the private MUC snapshot incomplete");
        }
        assert_affiliation_query_sequence(queries,
            { "member", "admin", "owner" }, "failed private MUC snapshot");
        if (stream.admin_iq_count != 3) {
            throw new IOError.FAILED(
                "a failed list must leave the parallel three-IQ snapshot incomplete, got %d IQs"
                    .printf(stream.admin_iq_count));
        }

        Gee.List<Jid>? passive_retry = yield
            muc_manager.query_private_muc_affiliation_snapshot(account,
                conversation.counterpart);
        if (passive_retry != null || stream.admin_iq_count != 3) {
            throw new IOError.FAILED(
                "a passive consumer must observe the failed join snapshot without silently retrying");
        }

        stream.fail_query_affiliation = null;
        Gee.List<Jid>? recovered_first = null;
        Gee.List<Jid>? recovered_second = null;
        bool first_done = false;
        bool second_done = false;
        muc_manager.ensure_private_muc_affiliation_snapshot.begin(account,
                conversation.counterpart, (obj, result) => {
            recovered_first = muc_manager
                .ensure_private_muc_affiliation_snapshot.end(result);
            first_done = true;
        });
        muc_manager.ensure_private_muc_affiliation_snapshot.begin(account,
                conversation.counterpart, (obj, result) => {
            recovered_second = muc_manager
                .ensure_private_muc_affiliation_snapshot.end(result);
            second_done = true;
        });
        for (int i = 0; i < 50 && (!first_done || !second_done); i++) {
            yield wait_muc_audit_tick();
        }
        if (!first_done || !second_done || recovered_first == null ||
                recovered_second == null ||
                !muc_manager.has_complete_private_muc_affiliation_snapshot(
                    account, conversation.counterpart)) {
            throw new IOError.FAILED(
                "parallel explicit retries must coalesce and recover a transient failure in the same join");
        }
        assert_affiliation_query_sequence(queries,
            { "member", "admin", "owner", "member", "admin", "owner" },
            "recovered private MUC snapshot");
        if (stream.admin_iq_count != 6) {
            throw new IOError.FAILED(
                "snapshot recovery must issue exactly one fresh three-IQ retry, got %d total"
                    .printf(stream.admin_iq_count));
        }
    }

    private void test_private_muc_mixed_unsent_waits_for_snapshot_recovery() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            MessageProcessor processor = (!) stream_interactor.get_module<
                MessageProcessor>(MessageProcessor.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname,
                null, null, "owner");
            stream.disco_members_only = true;
            stream.disco_non_anonymous = true;
            stream.defer_disco_info = true;
            stream.fail_query_affiliation = "admin";
            stream.set_server_affiliation_for_tests(account.bare_jid,
                "owner");
            stream.set_server_affiliation_for_tests(
                new Jid("bob@example.test"), "member");
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, stream);

            conversation.encryption = Encryption.NONE;
            processor.create_out_message("outbox-audit-none", conversation);
            conversation.encryption = Encryption.PGP;
            processor.create_out_message("outbox-audit-pgp", conversation);
            conversation.encryption = Encryption.OMEMO;
            processor.create_out_message("outbox-audit-omemo", conversation);

            int none_attempts = 0;
            int pgp_attempts = 0;
            int omemo_attempts = 0;
            ulong send_handler = processor.pre_message_send.connect(
                (message, stanza, target_conversation) => {
                    if (!target_conversation.account.equals(account) ||
                            !target_conversation.counterpart.equals_bare(
                                conversation.counterpart) ||
                            message.body == null ||
                            !((!) message.body).has_prefix(
                                "outbox-audit-")) return;
                    if (message.encryption == Encryption.NONE) {
                        none_attempts++;
                    } else if (message.encryption == Encryption.PGP) {
                        pgp_attempts++;
                    } else if (message.encryption == Encryption.OMEMO) {
                        omemo_attempts++;
                    }
                    // This audit observes dispatch ownership, not the crypto
                    // plugins. Settle the selected row synchronously so a
                    // later wake can prove that it is not selected twice.
                    message.marked = Message.Marked.WONTSEND;
                });

            MainLoop loop = new MainLoop();
            string? failure = null;
            bool timed_out = false;
            run_private_muc_mixed_unsent_recovery.begin(stream_interactor,
                muc_manager, processor, account, conversation, stream,
                () => none_attempts, () => pgp_attempts,
                () => omemo_attempts, (obj, res) => {
                    try {
                        run_private_muc_mixed_unsent_recovery.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(10, () => {
                timed_out = true;
                failure = "private MUC mixed UNSENT recovery timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (!timed_out) Source.remove(timeout_id);
            SignalHandler.disconnect(processor, send_handler);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private delegate int AttemptCount();

    private async void run_private_muc_mixed_unsent_recovery(
            StreamInteractor stream_interactor, MucManager muc_manager,
            MessageProcessor processor, Account account,
            Conversation conversation, MucManagerAuditStream stream,
            AttemptCount none_attempts, AttemptCount pgp_attempts,
            AttemptCount omemo_attempts) throws Error {
        Xmpp.Xep.Muc.JoinResult? joined = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(joined, "private MUC mixed UNSENT join");
        for (int i = 0; i < 12; i++) yield wait_muc_audit_tick();
        if (none_attempts() != 1 || pgp_attempts() != 0 ||
                omemo_attempts() != 0 ||
                !muc_manager.has_pending_muc_room_info(account,
                    conversation.counterpart)) {
            throw new IOError.FAILED(
                "pending room-info must dispatch only the persisted plaintext row");
        }

        stream.release_held_disco_successes();
        for (int i = 0; i < 40 && stream.admin_iq_count < 3; i++) {
            yield wait_muc_audit_tick();
        }
        for (int i = 0; i < 4; i++) yield wait_muc_audit_tick();
        if (muc_manager.has_complete_private_muc_affiliation_snapshot(account,
                conversation.counterpart) || none_attempts() != 1 ||
                pgp_attempts() != 0 || omemo_attempts() != 0) {
            throw new IOError.FAILED(
                "a failed private snapshot must leave encrypted UNSENT rows untouched");
        }

        stream.fail_query_affiliation = null;
        Gee.List<Jid>? recovered = yield
            muc_manager.ensure_private_muc_affiliation_snapshot(account,
                conversation.counterpart);
        for (int i = 0; i < 4; i++) yield wait_muc_audit_tick();
        if (recovered == null || pgp_attempts() != 1 ||
                omemo_attempts() != 1 || none_attempts() != 1) {
            throw new IOError.FAILED(
                "one successful explicit snapshot retry must wake each encrypted row exactly once");
        }

        conversation.encryption = Encryption.PGP;
        processor.create_out_message("outbox-audit-pgp-late", conversation);
        uint revision = muc_manager
            .get_private_muc_affiliation_snapshot_revision(account,
                conversation.counterpart);
        Gee.List<Jid>? cached = yield
            muc_manager.query_private_muc_affiliation_snapshot(account,
                conversation.counterpart);
        for (int i = 0; i < 4; i++) yield wait_muc_audit_tick();
        if (cached == null || pgp_attempts() != 1 ||
                muc_manager.get_private_muc_affiliation_snapshot_revision(
                    account, conversation.counterpart) != revision) {
            throw new IOError.FAILED(
                "a passive cached snapshot read must not spuriously dispatch the outbox");
        }

        stream_interactor.stream_resumed(account, stream);
        for (int i = 0; i < 12 && pgp_attempts() < 2; i++) {
            yield wait_muc_audit_tick();
        }
        if (pgp_attempts() != 2) {
            throw new IOError.FAILED(
                "a later stream resume must dispatch a new UNSENT row in the same snapshot revision");
        }
        stream_interactor.stream_resumed(account, stream);
        for (int i = 0; i < 8; i++) yield wait_muc_audit_tick();
        if (pgp_attempts() != 2 || omemo_attempts() != 1 ||
                none_attempts() != 1) {
            throw new IOError.FAILED(
                "duplicate resume triggers must not redispatch settled rows");
        }
    }

    private static bool jid_list_contains_bare(Gee.List<Jid> jids,
            Jid expected) {
        foreach (Jid jid in jids) {
            if (jid.equals_bare(expected)) return true;
        }
        return false;
    }

    private static void assert_private_muc_snapshot(MucManager muc_manager,
            Account account, Jid room, Jid[] expected, string context)
            throws Error {
        Gee.List<Jid>? snapshot =
            muc_manager.get_private_muc_member_affiliation_snapshot(account,
                room);
        if (snapshot == null || ((!) snapshot).size != expected.length) {
            throw new IOError.FAILED(
                "%s did not produce the expected complete snapshot size"
                    .printf(context));
        }
        foreach (Jid jid in expected) {
            if (!jid_list_contains_bare((!) snapshot, jid)) {
                throw new IOError.FAILED(
                    "%s omitted %s from the affiliation snapshot".printf(
                        context, jid.to_string()));
            }
        }
    }

    private static void assert_affiliation_query_sequence(
            Gee.List<string> actual, string[] expected, string context)
            throws Error {
        if (actual.size != expected.length) {
            string[] rendered = new string[actual.size];
            for (int i = 0; i < actual.size; i++) rendered[i] = actual[i];
            throw new IOError.FAILED(
                "%s issued %d affiliation queries instead of %d: %s".printf(
                    context, actual.size, expected.length,
                    string.joinv(",", rendered)));
        }
        for (int i = 0; i < expected.length; i++) {
            if (actual[i] != expected[i]) {
                throw new IOError.FAILED(
                    "%s affiliation query %d was %s instead of %s".printf(
                        context, i, actual[i], expected[i]));
            }
        }
    }

    private void test_private_muc_send_requires_joined_live_full_occupant() {
        with_active_muc((stream_interactor, account, room_conversation) => {
            MessageProcessor processor = (!) stream_interactor.get_module<MessageProcessor>(
                MessageProcessor.IDENTITY);
            ConversationManager conversation_manager = (!)
                stream_interactor.get_module<ConversationManager>(ConversationManager.IDENTITY);

            Conversation bare_target = conversation_manager.create_conversation(
                new Jid("bob@example.test"), account,
                Conversation.Type.GROUPCHAT_PM);
            Message bare_message = processor.create_out_message("bare target",
                bare_target);
            processor.send_xmpp_message(bare_message, bare_target);
            fail_if(bare_message.marked != Message.Marked.ERROR,
                "GROUPCHAT_PM must reject a bare real JID before touching the stream");

            Jid occupant = room_conversation.counterpart.with_resource("bob");
            Conversation private_conversation = conversation_manager.create_conversation(
                occupant, account, Conversation.Type.GROUPCHAT_PM);
            Message not_joined_message = processor.create_out_message("not joined",
                private_conversation);
            processor.send_xmpp_message(not_joined_message, private_conversation);
            fail_if(not_joined_message.marked != Message.Marked.ERROR,
                "GROUPCHAT_PM must reject sending while the account is not joined");

            var stream = new MucManagerAuditStream(new Jid("example.test"),
                room_conversation.counterpart, room_conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account, stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            Xmpp.Xep.Muc.Flag? muc_flag = stream.get_flag(
                Xmpp.Xep.Muc.Flag.IDENTITY);
            if (muc_flag == null) {
                throw new IOError.FAILED("test setup missing MUC flag");
            }
            ((!) muc_flag).set_muc_nick(room_conversation.counterpart.with_resource(
                room_conversation.nickname));
            stream.emit_presence(build_occupant_presence(
                room_conversation.counterpart, "bob",
                account.full_jid, "member", "participant",
                new Jid("bob@example.test/device")));
            stream.emit_presence(build_self_presence(room_conversation.counterpart,
                room_conversation.nickname, account.full_jid));

            // Opening the live member row binds the room/nick address to the
            // current real occupant identity.
            private_conversation = conversation_manager.create_conversation(
                occupant, account, Conversation.Type.GROUPCHAT_PM);
            fail_if_not_eq_str(private_conversation.muc_pm_peer_identity,
                "jid:bob@example.test",
                "a live PM thread must bind to the real bare occupant JID");

            Message live_message = processor.create_out_message("live occupant",
                private_conversation);
            processor.send_xmpp_message(live_message, private_conversation);
            // Exercise the non-default read marker so rebind has to persist
            // the NOT NULL -1 sentinel instead of attempting SQL NULL.
            private_conversation.read_up_to_item = 7;
            MainContext context = MainContext.@default();
            while (context.pending()) context.iteration(false);

            fail_if(stream.message_count != 1,
                "a joined current occupant must receive exactly one outgoing stanza");
            fail_if_not_eq_str(stream.last_message_to, occupant.to_string(),
                "GROUPCHAT_PM must retain the full occupant JID on the wire");
            fail_if_not_eq_str(stream.last_message_type,
                Xmpp.MessageStanza.TYPE_CHAT,
                "GROUPCHAT_PM must use a chat stanza");
            fail_if(!stream.last_message_has_muc_user,
                "GROUPCHAT_PM must include the muc#user marker");

            stream.emit_presence(build_unavailable_occupant_presence(
                room_conversation.counterpart, "bob", account.full_jid));
            Message stale_message = processor.create_out_message("stale occupant",
                private_conversation);
            processor.send_xmpp_message(stale_message, private_conversation);

            fail_if(stale_message.marked != Message.Marked.ERROR,
                "GROUPCHAT_PM must visibly reject a stale occupant target");
            fail_if(stream.message_count != 1,
                "a stale occupant target must not write another stanza");

            // A different person may later reuse the same room nickname. The
            // old conversation must stay blocked until a fresh member click
            // rebinds it, and that rebind must clear the old local thread.
            stream.emit_presence(build_occupant_presence(
                room_conversation.counterpart, "bob",
                account.full_jid, "member", "participant",
                new Jid("charlie@example.test/device")));
            Message reused_nick_message = processor.create_out_message(
                "must not reach charlie", private_conversation);
            processor.send_xmpp_message(reused_nick_message,
                private_conversation);
            fail_if(reused_nick_message.marked != Message.Marked.ERROR,
                "an old GROUPCHAT_PM thread must reject a reused nickname");
            fail_if(stream.message_count != 1,
                "a reused nickname must not receive a message from the old thread");

            Conversation rebound = conversation_manager.create_conversation(
                occupant, account, Conversation.Type.GROUPCHAT_PM);
            fail_if(rebound != private_conversation,
                "rebinding a nickname must keep one conversation row");
            fail_if_not_eq_str(rebound.muc_pm_peer_identity,
                "jid:charlie@example.test",
                "a fresh member click must bind the reused nick to its new identity");
            Database db = ((MucManagerTestApplication)
                GLib.Application.get_default()).db;
            fail_if(rebound.read_up_to_item != -1,
                "rebinding a reused nickname must reset its read marker safely");
            int? persisted_read_marker = db.conversation.select({
                    db.conversation.read_up_to_item })
                .with(db.conversation.id, "=", rebound.id)
                .single().row().get(db.conversation.read_up_to_item);
            fail_if(persisted_read_marker == null ||
                    (!) persisted_read_marker != -1,
                "the reset private-thread read marker must persist as -1");
            int64 old_thread_messages = db.message.select()
                .with(db.message.account_id, "=", account.id)
                .with(db.message.counterpart_id, "=",
                    db.get_jid_id(occupant))
                .with(db.message.counterpart_resource, "=", "bob")
                .with(db.message.type_, "=", Message.Type.GROUPCHAT_PM)
                .count();
            fail_if(old_thread_messages != 0,
                "rebinding a reused nick must remove the previous local PM history");
        });
    }

    private void test_private_muc_control_routing_never_binds_identity() {
        with_active_muc((stream_interactor, account, room_conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            ConversationManager conversation_manager = (!)
                stream_interactor.get_module<ConversationManager>(
                    ConversationManager.IDENTITY);
            Jid occupant = room_conversation.counterpart.with_resource("bob");
            Conversation private_conversation = conversation_manager
                .create_conversation(occupant, account,
                    Conversation.Type.GROUPCHAT_PM);
            private_conversation.muc_pm_peer_identity = null;
            muc_manager.remember_private_message_peer_identity_for_tests(
                account, occupant, "occupant-id:current-bob");

            Conversation? routed = conversation_manager
                .approx_conversation_for_stanza(occupant, account.full_jid,
                    account, Xmpp.MessageStanza.TYPE_CHAT);
            fail_if(routed != null,
                "A control stanza must not route through an unbound PM thread");
            fail_if(private_conversation.muc_pm_peer_identity != null,
                "Control routing must not bind the current occupant identity");
        });
    }

    private void test_private_muc_room_info_owns_conversation_encryption() {
        with_active_muc((stream_interactor, account, conversation) => {
            fail_if(conversation.encryption != Encryption.NONE,
                "an unknown room must start without inferred encryption");

            Database db = ((MucManagerTestApplication)
                GLib.Application.get_default()).db;
            var test_settings = new Dino.Entities.Settings.from_db(db);
            test_settings.set_default_encryption(account, Encryption.PGP);

            ConversationManager conversation_manager = stream_interactor
                .get_module<ConversationManager>(ConversationManager.IDENTITY);
            Jid pgp_room = new Jid("pgp@conference.example.test");
            Conversation pgp_conversation = conversation_manager
                .create_conversation(pgp_room, account,
                    Conversation.Type.GROUPCHAT);
            pgp_conversation.encryption = Encryption.PGP;
            Jid omemo_room = new Jid("omemo@conference.example.test");
            Conversation omemo_conversation = conversation_manager
                .create_conversation(omemo_room, account,
                    Conversation.Type.GROUPCHAT);
            omemo_conversation.encryption = Encryption.OMEMO;

            // Exercise the same DB hydration path used after an application
            // restart, including old private rooms persisted as NONE.
            stream_interactor.account_removed(account);
            stream_interactor.module_manager.remove(account);
            stream_interactor.module_manager.initialize(account);
            stream_interactor.account_added(account);
            Conversation? restored_none = conversation_manager
                .get_conversation(conversation.counterpart, account,
                    Conversation.Type.GROUPCHAT);
            Conversation? restored_pgp = conversation_manager
                .get_conversation(pgp_room, account,
                    Conversation.Type.GROUPCHAT);
            Conversation? restored_omemo = conversation_manager
                .get_conversation(omemo_room, account,
                    Conversation.Type.GROUPCHAT);
            if (restored_none == null || restored_pgp == null ||
                    restored_omemo == null ||
                    ((!) restored_none).encryption != Encryption.NONE ||
                    ((!) restored_pgp).encryption != Encryption.PGP ||
                    ((!) restored_omemo).encryption != Encryption.OMEMO) {
                throw new IOError.FAILED(
                    "persisted NONE, PGP and OMEMO room modes must survive DB hydration before authoritative room info");
            }

            var stream = new MucManagerAuditStream(new Jid("example.test"),
                ((!) restored_none).counterpart,
                ((!) restored_none).nickname);
            stream.disco_members_only = true;
            stream.disco_non_anonymous = true;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager
                .set_connected_stream_for_tests(account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_private_muc_encryption_room_info_audit.begin(
                stream_interactor, account, (!) restored_none,
                (!) restored_pgp, (!) restored_omemo, stream,
                (obj, result) => {
                    try {
                        run_private_muc_encryption_room_info_audit.end(result);
                    } catch (Error error) {
                        failure = error.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "private-MUC encryption room-info audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            if (timeout_id != 0) Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_private_muc_encryption_room_info_audit(
            StreamInteractor stream_interactor, Account account,
            Conversation conversation, Conversation pgp_conversation,
            Conversation omemo_conversation,
            MucManagerAuditStream stream)
            throws Error {
        Xmpp.Xep.Muc.Module muc_module = stream.get_module<
            Xmpp.Xep.Muc.Module>(Xmpp.Xep.Muc.Module.IDENTITY);
        MucManager muc_manager = stream_interactor.get_module<MucManager>(
            MucManager.IDENTITY);

        bool private_info_loaded = yield muc_module.query_room_info(stream,
            conversation.counterpart);
        Encryption expected = Encryption.PGP;
        if (!private_info_loaded ||
                !muc_manager.is_private_room(account,
                    conversation.counterpart) ||
                conversation.encryption != expected) {
            throw new IOError.FAILED(
                "authoritative private room info must apply the account encryption default in the core");
        }

        bool pgp_info_loaded = yield muc_module.query_room_info(stream,
            pgp_conversation.counterpart);
        bool omemo_info_loaded = yield muc_module.query_room_info(stream,
            omemo_conversation.counterpart);
        if (!pgp_info_loaded || !omemo_info_loaded ||
                pgp_conversation.encryption != Encryption.PGP ||
                omemo_conversation.encryption != Encryption.OMEMO) {
            throw new IOError.FAILED(
                "authoritative private room info must preserve explicit persisted PGP and OMEMO selections");
        }

        Jid preknown_room = new Jid(
            "preknown@conference.example.test");
        bool preknown_info_loaded = yield muc_module.query_room_info(stream,
            preknown_room);
        Conversation preknown_conversation = stream_interactor.get_module<
            ConversationManager>(ConversationManager.IDENTITY)
                .create_conversation(preknown_room, account,
                    Conversation.Type.GROUPCHAT);
        if (!preknown_info_loaded ||
                preknown_conversation.encryption != expected) {
            throw new IOError.FAILED(
                "room info that arrives before conversation creation must still select the account encryption default");
        }

        stream.disco_error_condition =
            Xmpp.ErrorStanza.CONDITION_SERVICE_UNAVAILABLE;
        bool failed_refresh = yield muc_module.query_room_info(stream,
            conversation.counterpart);
        stream.disco_error_condition = null;
        if (failed_refresh || conversation.encryption != expected) {
            throw new IOError.FAILED(
                "a failed room-info refresh must not rewrite the retained encryption mode");
        }

        stream.disco_members_only = false;
        bool public_info_loaded = yield muc_module.query_room_info(stream,
            conversation.counterpart);
        bool public_pgp_info_loaded = yield muc_module.query_room_info(stream,
            pgp_conversation.counterpart);
        bool public_omemo_info_loaded = yield muc_module.query_room_info(stream,
            omemo_conversation.counterpart);
        if (!public_info_loaded ||
                !public_pgp_info_loaded || !public_omemo_info_loaded ||
                muc_manager.is_private_room(account,
                    conversation.counterpart) ||
                conversation.encryption != Encryption.NONE ||
                pgp_conversation.encryption != Encryption.NONE ||
                omemo_conversation.encryption != Encryption.NONE) {
            throw new IOError.FAILED(
                "authoritative public room info must disable room encryption in the core");
        }
    }

    private void test_private_muc_identity_upgrade_preserves_thread() {
        with_active_muc((stream_interactor, account, room_conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            ConversationManager conversation_manager = (!)
                stream_interactor.get_module<ConversationManager>(
                    ConversationManager.IDENTITY);
            MessageProcessor processor = (!)
                stream_interactor.get_module<MessageProcessor>(
                    MessageProcessor.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                room_conversation.counterpart, room_conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            Xmpp.Xep.Muc.Flag? flag = stream.get_flag(
                Xmpp.Xep.Muc.Flag.IDENTITY);
            if (flag == null) throw new IOError.FAILED("test setup missing MUC flag");
            ((!) flag).set_muc_nick(room_conversation.counterpart.with_resource(
                room_conversation.nickname));
            Jid occupant = room_conversation.counterpart.with_resource(
                "anonymous");
            stream.emit_presence(build_anonymous_occupant_presence(
                room_conversation.counterpart, "anonymous", account.full_jid));

            muc_manager.remember_private_message_peer_identity_for_tests(
                account, occupant, "session:1:100");
            Conversation private_conversation =
                conversation_manager.create_conversation(occupant, account,
                    Conversation.Type.GROUPCHAT_PM);
            Message retained = processor.create_out_message(
                "identity upgrade must retain this message",
                private_conversation);
            private_conversation.read_up_to_item = 9;

            muc_manager.remember_private_message_peer_identity_for_tests(
                account, occupant, "occupant-id:stable-occupant");
            Conversation after_occupant_id =
                conversation_manager.create_conversation(occupant, account,
                    Conversation.Type.GROUPCHAT_PM);
            fail_if(after_occupant_id != private_conversation,
                "identity evidence upgrade must keep the current PM conversation");
            fail_if_not_eq_str(after_occupant_id.muc_pm_peer_identity,
                "occupant-id:stable-occupant",
                "XEP-0421 must promote a transient PM identity");
            fail_if(after_occupant_id.read_up_to_item != 9,
                "identity evidence upgrade must preserve the read marker");

            muc_manager.remember_private_message_peer_identity_for_tests(
                account, occupant, "jid:anonymous@example.test");
            Conversation after_real_jid =
                conversation_manager.create_conversation(occupant, account,
                    Conversation.Type.GROUPCHAT_PM);
            fail_if(after_real_jid != private_conversation,
                "real-JID promotion must keep the continuously-live PM thread");
            fail_if_not_eq_str(after_real_jid.muc_pm_peer_identity,
                "jid:anonymous@example.test",
                "real JID must become the strongest PM identity");
            fail_if(after_real_jid.read_up_to_item != 9,
                "real-JID promotion must not reset the thread read marker");

            muc_manager.forget_private_message_real_jid_for_tests(account,
                occupant);
            fail_if_not_eq_str(
                muc_manager.get_private_message_peer_identity(account,
                    occupant),
                "occupant-id:stable-occupant",
                "revoked real-JID disclosure must fall back to XEP-0421 identity");
            fail_if(conversation_manager.create_conversation(occupant, account,
                    Conversation.Type.GROUPCHAT_PM) != private_conversation,
                "privacy revocation must preserve the continuously-live PM thread");

            muc_manager.remember_private_message_peer_identity_for_tests(
                account, occupant, "jid:anonymous@example.test");
            Jid other_room_occupant = new Jid(
                "other@conference.example.test/anonymous");
            muc_manager.remember_private_message_peer_identity_for_tests(
                account, other_room_occupant, "jid:other@example.test");
            muc_manager.forget_room_private_message_real_jids_for_tests(
                account, room_conversation.counterpart);
            fail_if_not_eq_str(
                muc_manager.get_private_message_peer_identity(account,
                    occupant),
                "occupant-id:stable-occupant",
                "room-wide privacy revocation must demote every jid alias in that room");
            fail_if_not_eq_str(
                muc_manager.get_remembered_private_message_peer_identity_for_tests(
                    account, other_room_occupant),
                "jid:other@example.test",
                "room-wide privacy revocation must not touch another room");

            MessageStorage message_storage = (!)
                stream_interactor.get_module<MessageStorage>(
                    MessageStorage.IDENTITY);
            fail_if(message_storage.get_last_message(after_real_jid) != retained,
                "continuous identity promotion must preserve PM history");
        });
    }

    private void test_room_pm_identity_purge_is_room_scoped() {
        with_active_muc((stream_interactor, account, room_conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                room_conversation.counterpart, room_conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, room_conversation);

            Jid room_a_occupant = room_conversation.counterpart.with_resource(
                "reused-nick");
            stream.emit_presence(build_anonymous_occupant_presence(
                room_conversation.counterpart, "reused-nick",
                account.full_jid));

            string old_session = "session:1:100";
            string old_occupant_id = "occupant-id:old-occupant";
            string old_real_jid = "jid:old-peer@example.test";
            muc_manager.remember_private_message_peer_identity_for_tests(
                account, room_a_occupant, old_session);
            muc_manager.remember_private_message_peer_identity_for_tests(
                account, room_a_occupant, old_occupant_id);
            muc_manager.remember_private_message_peer_identity_for_tests(
                account, room_a_occupant, old_real_jid);

            fail_if(!muc_manager.private_message_peer_identity_matches(
                        account, room_a_occupant, old_session) ||
                    !muc_manager.private_message_peer_identity_matches(
                        account, room_a_occupant, old_occupant_id) ||
                    !muc_manager.private_message_peer_identity_matches(
                        account, room_a_occupant, old_real_jid),
                "test setup must retain session, occupant-id and JID aliases for one live nick");

            Jid room_b_occupant = new Jid(
                "other@conference.example.test/reused-nick");
            muc_manager.remember_private_message_peer_identity_for_tests(
                account, room_b_occupant, "session:7:700");
            muc_manager.remember_private_message_peer_identity_for_tests(
                account, room_b_occupant,
                "occupant-id:other-room-occupant");
            muc_manager.remember_private_message_peer_identity_for_tests(
                account, room_b_occupant, "jid:other-peer@example.test");

            muc_manager.forget_room_private_message_peer_identities_for_tests(
                account, room_conversation.counterpart);

            fail_if(muc_manager.get_remembered_private_message_peer_identity_for_tests(
                        account, room_a_occupant) != null ||
                    muc_manager.private_message_peer_identity_matches(
                        account, room_a_occupant, old_session) ||
                    muc_manager.private_message_peer_identity_matches(
                        account, room_a_occupant, old_occupant_id) ||
                    muc_manager.private_message_peer_identity_matches(
                        account, room_a_occupant, old_real_jid),
                "a room boundary must remove every PM identity and alias for that room");
            fail_if_not_eq_str(
                muc_manager.get_remembered_private_message_peer_identity_for_tests(
                    account, room_b_occupant),
                "jid:other-peer@example.test",
                "purging room A must preserve room B's PM identity");

            string new_session = "session:2:200";
            muc_manager.remember_private_message_peer_identity_for_tests(
                account, room_a_occupant, new_session);
            fail_if(!muc_manager.private_message_peer_identity_matches(
                        account, room_a_occupant, new_session) ||
                    muc_manager.private_message_peer_identity_matches(
                        account, room_a_occupant, old_session) ||
                    muc_manager.private_message_peer_identity_matches(
                        account, room_a_occupant, old_occupant_id) ||
                    muc_manager.private_message_peer_identity_matches(
                        account, room_a_occupant, old_real_jid),
                "the same nick after a room boundary must start a new session without inheriting old aliases");
        });
    }

    private void test_stale_occupant_identity_signals_without_lifecycle_are_ignored() {
        with_active_muc((stream_interactor, account, room_conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                room_conversation.counterpart, room_conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            Jid occupant = room_conversation.counterpart.with_resource(
                "late-peer");
            Jid real_jid = new Jid("late-peer@example.test");
            Xmpp.Xep.Muc.Module muc_module =
                stream_interactor.module_manager.get_module<
                    Xmpp.Xep.Muc.Module>(account,
                        Xmpp.Xep.Muc.Module.IDENTITY);
            Xmpp.Xep.OccupantIds.Module occupant_ids_module =
                stream_interactor.module_manager.get_module<
                    Xmpp.Xep.OccupantIds.Module>(account,
                        Xmpp.Xep.OccupantIds.Module.IDENTITY);

            // Simulate callbacks from a delayed available presence after the
            // room lifecycle was already cancelled.  These signals used to
            // recreate PM and own-occupant identity state with no live room.
            muc_module.received_occupant_jid(stream, occupant, real_jid);
            occupant_ids_module.received_occupant_id(stream, occupant,
                "stale-occupant-id");
            occupant_ids_module.received_own_occupant_id(stream, occupant,
                "stale-own-id");

            fail_if(muc_manager
                    .get_remembered_private_message_peer_identity_for_tests(
                        account, occupant) != null,
                "identity callbacks without a current room generation must not recreate a purged PM identity");
            fail_if(muc_manager.get_own_occupant_id(account,
                    room_conversation.counterpart) != null,
                "an own occupant-id without a current room generation must be ignored");
        });
    }

    private void test_v44_migration_preserves_private_muc_identity() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-conversation-v44-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        const string db_key = "conversation-v44-test";
        Sqlite.Database? raw_db = null;
        Database? migrated_db = null;

        try {
            cleanup_muc_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);

            int open_result = Sqlite.Database.open_v2(db_path, out raw_db,
                Sqlite.OPEN_READWRITE | Sqlite.OPEN_CREATE | 0x00010000);
            if (open_result != Sqlite.OK) {
                throw new IOError.FAILED("could not create synthetic v44 database");
            }
            sqlite_exec_or_throw((!) raw_db, "PRAGMA key = 'conversation-v44-test'");
            sqlite_exec_or_throw((!) raw_db,
                "CREATE TABLE _meta (name TEXT PRIMARY KEY, int_val INTEGER, text_val TEXT)");
            sqlite_exec_or_throw((!) raw_db,
                "INSERT INTO _meta (name, int_val) VALUES ('version', 44)");
            sqlite_exec_or_throw((!) raw_db, """
                CREATE TABLE account (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    bare_jid TEXT UNIQUE NOT NULL,
                    resourcepart TEXT, password TEXT, alias TEXT, enabled INTEGER,
                    roster_version TEXT, mam_earliest_synced INTEGER,
                    custom_host TEXT, custom_port INTEGER,
                    proxy_type TEXT DEFAULT 'none', proxy_host TEXT, proxy_port INTEGER,
                    proxy_user TEXT, proxy_pass TEXT, require_channel_binding INTEGER DEFAULT 0
                )
            """);
            sqlite_exec_or_throw((!) raw_db,
                "INSERT INTO account (id, bare_jid, resourcepart, password, enabled) " +
                "VALUES (1, 'alice@example.test', 'dinox', 'secret', 1)");
            sqlite_exec_or_throw((!) raw_db,
                "CREATE TABLE jid (id INTEGER PRIMARY KEY AUTOINCREMENT, bare_jid TEXT UNIQUE NOT NULL)");
            sqlite_exec_or_throw((!) raw_db,
                "INSERT INTO jid (id, bare_jid) VALUES (1, 'room@conference.example.test')");
            sqlite_exec_or_throw((!) raw_db, """
                CREATE TABLE conversation (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_id INTEGER NOT NULL,
                    jid_id INTEGER NOT NULL,
                    resource TEXT,
                    active INTEGER,
                    active_last_changed INTEGER NOT NULL DEFAULT 0,
                    last_active INTEGER,
                    type INTEGER,
                    encryption INTEGER,
                    read_up_to INTEGER,
                    read_up_to_item INTEGER NOT NULL DEFAULT -1,
                    notification INTEGER,
                    send_typing INTEGER,
                    send_marker INTEGER,
                    pinned INTEGER DEFAULT 0,
                    history_cleared_at INTEGER DEFAULT 0,
                    message_expiry_seconds INTEGER DEFAULT 0,
                    UNIQUE (account_id, jid_id, type) ON CONFLICT IGNORE
                )
            """);
            sqlite_exec_or_throw((!) raw_db, """
                INSERT INTO conversation (
                    id, account_id, jid_id, resource, active,
                    active_last_changed, type, encryption, read_up_to_item,
                    notification, send_typing, send_marker, pinned,
                    history_cleared_at, message_expiry_seconds
                ) VALUES (7, 1, 1, 'first', 1, 0, 2, 0, -1, 0, 0, 0, 0, 0, 0)
            """);
            raw_db = null;

            migrated_db = new Database(db_path, db_key);
            Gee.List<Account> accounts = ((!) migrated_db).get_accounts();
            if (accounts.size != 1) throw new IOError.FAILED("migrated account was not preserved");
            Account account = accounts[0];
            Jid room = new Jid("room@conference.example.test");

            Conversation second = new Conversation(room.with_resource("second"), account,
                Conversation.Type.GROUPCHAT_PM);
            second.persist((!) migrated_db);
            if (second.id == 7 || second.id <= 0) {
                throw new IOError.FAILED("second MUC occupant did not receive a distinct migrated identity");
            }
            Conversation duplicate = new Conversation(room.with_resource("first"), account,
                Conversation.Type.GROUPCHAT_PM);
            duplicate.persist((!) migrated_db);
            if (duplicate.id != 7) {
                throw new IOError.FAILED("duplicate occupant identity was not resolved to the legacy row");
            }
            ((!) migrated_db).close();
            migrated_db = null;

            migrated_db = new Database(db_path, db_key);
            Account reopened_account = ((!) migrated_db).get_accounts()[0];
            Gee.List<Conversation> reopened = ((!) migrated_db).get_conversations(reopened_account);
            bool found_first = false;
            bool found_second = false;
            foreach (Conversation conversation in reopened) {
                if (conversation.type_ != Conversation.Type.GROUPCHAT_PM) continue;
                if (conversation.counterpart.equals(room.with_resource("first"))) found_first = true;
                if (conversation.counterpart.equals(room.with_resource("second"))) found_second = true;
            }
            if (!found_first || !found_second) {
                throw new IOError.FAILED("private MUC occupant identities did not survive v44 migration and reopen");
            }
        } catch (Error e) {
            fail_if_reached("Unexpected error in v44 conversation migration audit: %s".printf(e.message));
        } finally {
            raw_db = null;
            if (migrated_db != null) ((!) migrated_db).close();
            cleanup_muc_test_dir(temp_dir, db_path);
        }
    }

    private void test_unchanged_members_only_does_not_preflight_affiliations() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(
                new Jid("example.test"), conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account, stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);
            establish_owner_context(stream, account, conversation);
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_membersonly", "boolean", "1");
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_roomdesc", "text-single",
                "Original description");

            var form_node = new StanzaNode.build("x", Xmpp.Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "form")
                .put_node(build_config_field("muc#roomconfig_membersonly", "boolean", "1"))
                .put_node(build_config_field("muc#roomconfig_roomdesc", "text-single", "Original description"));
            Xmpp.Xep.DataForms.DataForm form = parse_and_change_config_field(
                form_node, "muc#roomconfig_roomdesc", "Updated description");

            MainLoop loop = new MainLoop();
            string? failure = null;
            save_unchanged_members_only_form.begin(muc_manager, account, conversation.counterpart,
                form, stream, (obj, res) => {
                    try {
                        save_unchanged_members_only_form.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out waiting for room configuration submit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void save_unchanged_members_only_form(MucManager muc_manager,
                                                        Account account,
                                                        Jid room,
                                                        Xmpp.Xep.DataForms.DataForm form,
                                                        MucManagerAuditStream stream) throws Error {
        bool saved = yield muc_manager.set_config_form(account, room, form, true);
        if (!saved) throw new IOError.FAILED("room configuration submit was rejected");
        if (stream.owner_config_set_count != 1 ||
                stream.owner_config_get_count != 1) {
            throw new IOError.FAILED(
                "room configuration must send one owner SET and one verifying GET");
        }
        if (stream.admin_iq_count != 0 || stream.admin_set_count != 0) {
            throw new IOError.FAILED(
                "an independent edit with an unchanged members-only baseline must not query or mutate affiliations");
        }
        if (stream.get_server_config_value_for_tests(
                    "muc#roomconfig_membersonly") != "1" ||
                stream.get_server_config_value_for_tests(
                    "muc#roomconfig_roomdesc") != "Updated description") {
            throw new IOError.FAILED(
                "the server model must apply the changed field without losing the unchanged members-only value");
        }
    }

    private void test_room_config_verification_mismatch_is_local_sync_warning() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.apply_owner_config_set_values = false;
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_membersonly", "boolean", "1");
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_roomdesc", "text-single",
                "Original description");
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);

            var form_node = new StanzaNode.build("x",
                    Xmpp.Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "form")
                .put_node(build_config_field(
                    "muc#roomconfig_membersonly", "boolean", "1"))
                .put_node(build_config_field(
                    "muc#roomconfig_roomdesc", "text-single",
                    "Original description"));
            Xmpp.Xep.DataForms.DataForm form = parse_and_change_config_field(
                form_node, "muc#roomconfig_roomdesc", "Updated description");

            MainLoop loop = new MainLoop();
            MucConfigSaveResult? result = null;
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*changed server values could not be confirmed*");
            muc_manager.set_config_form_detailed.begin(account,
                conversation.counterpart, form, true, (obj, res) => {
                    result = muc_manager.set_config_form_detailed.end(res);
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            GLib.Test.assert_expected_messages();

            fail_if(result == null || (!) result !=
                    MucConfigSaveResult.APPLIED_SERVER_STATE_UNVERIFIED,
                "an unconfirmed owner SET must report an applied local-sync warning");
            fail_if(stream.owner_config_set_count != 1 ||
                    stream.owner_config_get_count != 1,
                "a verification mismatch must use one owner SET and one owner GET without retrying");
            fail_if(stream.admin_iq_count != 0,
                "a verification mismatch for an independent edit must not touch affiliations");
            fail_if(stream.get_server_config_value_for_tests(
                    "muc#roomconfig_roomdesc") != "Original description",
                "the mismatch fake must retain the original server value");
        });
    }

    private void test_room_config_verification_get_error_is_local_sync_warning() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.owner_config_get_error_condition =
                Xmpp.ErrorStanza.CONDITION_FORBIDDEN;
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_membersonly", "boolean", "1");
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_roomdesc", "text-single",
                "Original description");
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);

            var form_node = new StanzaNode.build("x",
                    Xmpp.Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "form")
                .put_node(build_config_field(
                    "muc#roomconfig_membersonly", "boolean", "1"))
                .put_node(build_config_field(
                    "muc#roomconfig_roomdesc", "text-single",
                    "Original description"));
            Xmpp.Xep.DataForms.DataForm form = parse_and_change_config_field(
                form_node, "muc#roomconfig_roomdesc", "Updated description");

            MainLoop loop = new MainLoop();
            MucConfigSaveResult? result = null;
            GLib.Test.expect_message("xmpp-vala", LogLevelFlags.LEVEL_WARNING,
                "*Failed to get config form*");
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*changed server values could not be confirmed*");
            muc_manager.set_config_form_detailed.begin(account,
                conversation.counterpart, form, true, (obj, res) => {
                    result = muc_manager.set_config_form_detailed.end(res);
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            GLib.Test.assert_expected_messages();

            fail_if(result == null || (!) result !=
                    MucConfigSaveResult.APPLIED_SERVER_STATE_UNVERIFIED,
                "a failed verification GET must report an applied local-sync warning");
            fail_if(stream.owner_config_set_count != 1 ||
                    stream.owner_config_get_count != 1,
                "a failed verification GET must not retry the confirmed owner SET");
            fail_if(stream.admin_iq_count != 0,
                "a failed verification GET for an independent edit must not touch affiliations");
            fail_if(stream.get_server_config_value_for_tests(
                    "muc#roomconfig_roomdesc") != "Updated description",
                "the server model must retain the value applied before verification failed");
        });
    }

    private void test_members_only_query_failure_sends_no_mutation() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.fail_query_affiliation = "admin";
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);

            Xmpp.Xep.DataForms.DataForm form =
                build_members_only_transition_form(false, true);

            MainLoop loop = new MainLoop();
            MucConfigSaveResult? result = null;
            GLib.Test.expect_message("libdino",
                LogLevelFlags.LEVEL_WARNING,
                "*Could not make current occupants members before enabling members-only*");
            muc_manager.set_config_form_detailed.begin(account,
                conversation.counterpart, form, false, (obj, res) => {
                    result = muc_manager.set_config_form_detailed.end(res);
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            GLib.Test.assert_expected_messages();

            fail_if(result == null, "members-only failure audit timed out");
            fail_if((!) result != MucConfigSaveResult.REJECTED,
                "a failed affiliation query must be a clean room-configuration rejection");
            fail_if(stream.admin_set_count != 0,
                "a failed affiliation query must not send affiliation mutations");
            fail_if(stream.owner_config_set_count != 0,
                "a failed affiliation query must not submit the room form");
        });
    }

    private void test_members_only_unknown_original_sends_no_mutation() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);

            Xmpp.Xep.DataForms.DataForm form =
                build_members_only_transition_form(false, true);

            MainLoop loop = new MainLoop();
            bool? saved = null;
            muc_manager.set_config_form.begin(account,
                conversation.counterpart, form, null, (obj, res) => {
                    saved = muc_manager.set_config_form.end(res);
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);

            fail_if(saved == null || !((!) saved),
                "an unknown UI baseline must remain safe by running the server preflight");
            fail_if(stream.admin_iq_count != 3 ||
                    stream.admin_set_count != 0 ||
                    stream.owner_config_set_count != 1 ||
                    stream.owner_config_get_count != 1,
                "an unknown baseline must query every affiliation list, submit once and verify once without redundant grants");
        });
    }

    private void test_members_only_config_failure_rolls_back_preflight() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.owner_config_set_error_condition =
                Xmpp.ErrorStanza.CONDITION_FORBIDDEN;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            establish_owner_context(stream, account, conversation);
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "bob", account.full_jid, "none",
                "participant", new Jid("bob@example.test/device")));

            Xmpp.Xep.DataForms.DataForm form =
                build_members_only_transition_form(false, true);

            MainLoop loop = new MainLoop();
            MucConfigSaveResult? result = null;
            GLib.Test.expect_message("xmpp-vala",
                LogLevelFlags.LEVEL_WARNING,
                "*Failed to set config form*");
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*Preserving preflight membership*cannot safely compare-and-set a rollback*");
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*configuration was rejected*rollback is incomplete*");
            muc_manager.set_config_form_detailed.begin(account,
                conversation.counterpart, form, false, (obj, res) => {
                    result = muc_manager.set_config_form_detailed.end(res);
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            GLib.Test.assert_expected_messages();

            fail_if(result == null,
                "members-only partial-result audit timed out");
            fail_if((!) result !=
                    MucConfigSaveResult.REJECTED_PREFLIGHT_MEMBERS_PRESERVED,
                "a rejected room form after membership grants must report the preserved partial side effect");
            fail_if(stream.owner_config_set_count != 1,
                "the rollback audit must reach exactly one config submit");
            int granted = 0;
            int restored = 0;
            foreach (string affiliation in stream.admin_set_affiliations) {
                if (affiliation == "member") granted++;
                if (affiliation == "none") restored++;
            }
            fail_if(granted == 0 || restored != 0,
                "a rejected config must preserve granted membership rather than send an ambiguous destructive rollback");
            fail_if(stream.get_server_affiliation_for_tests(
                    new Jid("bob@example.test")) != "member",
                "the safely preserved preflight membership must remain on the server model");
        });
    }

    private void test_members_only_unresolved_occupant_fails_before_mutation() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            establish_owner_context(stream, account, conversation);
            stream.emit_presence(build_anonymous_occupant_presence(
                conversation.counterpart, "anonymous", account.full_jid));

            Xmpp.Xep.DataForms.DataForm form =
                build_members_only_transition_form(false, true);

            MainLoop loop = new MainLoop();
            bool? saved = null;
            GLib.Test.expect_message("libdino",
                LogLevelFlags.LEVEL_WARNING,
                "*Could not make current occupants members before enabling members-only*Could not resolve current occupant*");
            muc_manager.set_config_form.begin(account,
                conversation.counterpart, form, false, (obj, res) => {
                    saved = muc_manager.set_config_form.end(res);
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            GLib.Test.assert_expected_messages();

            fail_if(saved == null,
                "unresolved occupant members-only audit timed out");
            fail_if((!) saved,
                "members-only must fail closed for an unresolved live occupant");
            fail_if(stream.admin_set_count != 0,
                "preflight validation must finish before any affiliation mutation");
            fail_if(stream.owner_config_set_count != 0,
                "an unresolved occupant must prevent the owner form submit");
        });
    }

    private void test_members_only_demotion_during_preflight_stops_mutation() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "bob", account.full_jid, "none",
                "participant", new Jid("bob@example.test/device")));

            bool demoted = false;
            string? hook_failure = null;
            stream.affiliation_query_received.connect((affiliation) => {
                if (demoted || affiliation != "member") return;
                demoted = true;
                try {
                    stream.emit_presence(build_self_presence(
                        conversation.counterpart, conversation.nickname,
                        account.full_jid, "member"));
                } catch (Error e) {
                    hook_failure = e.message;
                }
            });

            Xmpp.Xep.DataForms.DataForm form =
                build_members_only_transition_form(false, true);

            MainLoop loop = new MainLoop();
            bool? saved = null;
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*Could not make current occupants members before enabling members-only*Owner context changed*");
            muc_manager.set_config_form.begin(account,
                conversation.counterpart, form, false, (obj, res) => {
                    saved = muc_manager.set_config_form.end(res);
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            GLib.Test.assert_expected_messages();

            if (hook_failure != null) throw new IOError.FAILED((!) hook_failure);
            fail_if_not(demoted,
                "the audit must demote the owner during affiliation preflight");
            fail_if(saved == null || (!) saved,
                "an Owner demotion during preflight must fail closed");
            fail_if(stream.admin_set_count != 0,
                "an Owner demotion must stop before affiliation mutation");
            fail_if(stream.owner_config_set_count != 0,
                "an Owner demotion must stop before the config IQ");
        });
    }

    private void test_members_only_stream_change_during_preflight_stops_mutation() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            var replacement = new MucManagerAuditStream(
                new Jid("replacement.example.test"), conversation.counterpart,
                conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "bob", account.full_jid, "none",
                "participant", new Jid("bob@example.test/device")));

            bool switched = false;
            stream.affiliation_query_received.connect((affiliation) => {
                if (switched || affiliation != "member") return;
                switched = true;
                try {
                    attach_muc_stream_modules_for_tests(stream_interactor,
                        account, replacement);
                } catch (Error e) {
                    GLib.error("Could not attach replacement audit stream: %s", e.message);
                }
                stream_interactor.connection_manager.set_connected_stream_for_tests(
                    account, replacement);
            });

            Xmpp.Xep.DataForms.DataForm form =
                build_members_only_transition_form(false, true);

            MainLoop loop = new MainLoop();
            bool? saved = null;
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*Could not make current occupants members before enabling members-only*Owner context changed*");
            muc_manager.set_config_form.begin(account,
                conversation.counterpart, form, false, (obj, res) => {
                    saved = muc_manager.set_config_form.end(res);
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            GLib.Test.assert_expected_messages();

            fail_if_not(switched,
                "the audit must replace the stream during affiliation preflight");
            fail_if(saved == null || (!) saved,
                "a stream change during preflight must fail closed");
            fail_if(stream.admin_set_count != 0,
                "a stream change must stop before affiliation mutation");
            fail_if(stream.owner_config_set_count != 0,
                "a stream change must stop before the config IQ");
        });
    }

    private void test_config_same_stream_rejoin_generation_is_stale() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            muc_manager.set_muc_occupant_room_generation_for_tests(account,
                conversation.counterpart, 1);
            establish_owner_context(stream, account, conversation);
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_membersonly", "boolean", "1");
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_roomdesc", "text-single",
                "Original description");

            bool generation_advanced = false;
            stream.owner_config_set_received.connect(() => {
                generation_advanced = true;
                muc_manager.advance_muc_occupant_room_generation_for_tests(
                    account, conversation.counterpart);
            });

            var form_node = new StanzaNode.build("x",
                    Xmpp.Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "form")
                .put_node(build_config_field(
                    "muc#roomconfig_membersonly", "boolean", "1"))
                .put_node(build_config_field(
                    "muc#roomconfig_roomdesc", "text-single",
                    "Original description"));
            Xmpp.Xep.DataForms.DataForm form = parse_and_change_config_field(
                form_node, "muc#roomconfig_roomdesc", "Updated description");

            MainLoop loop = new MainLoop();
            MucConfigSaveResult? result = null;
            muc_manager.set_config_form_detailed.begin(account,
                conversation.counterpart, form, true, (obj, res) => {
                    result = muc_manager.set_config_form_detailed.end(res);
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);

            fail_if_not(generation_advanced,
                "the audit must advance the same-stream room generation");
            fail_if(result == null || (!) result !=
                    MucConfigSaveResult.APPLIED_SERVER_STATE_UNVERIFIED,
                "a config from the previous room generation must remain unverified");
            fail_if(stream.owner_config_set_count != 1,
                "the generation race must happen while one config IQ is in flight");
        });
    }

    private void test_get_config_same_stream_rejoin_generation_is_stale() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            muc_manager.set_muc_occupant_room_generation_for_tests(account,
                conversation.counterpart, 1);
            establish_owner_context(stream, account, conversation);

            stream.owner_config_get_received.connect(() => {
                muc_manager.advance_muc_occupant_room_generation_for_tests(
                    account, conversation.counterpart);
            });

            MainLoop loop = new MainLoop();
            Xmpp.Xep.DataForms.DataForm? form = null;
            bool completed = false;
            muc_manager.get_config_form.begin(account,
                conversation.counterpart, (obj, res) => {
                    form = muc_manager.get_config_form.end(res);
                    completed = true;
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);

            fail_if_not(completed,
                "stale config GET audit must complete");
            fail_if(form != null,
                "a config form from an earlier room generation must be discarded");
            fail_if(stream.owner_config_get_count != 1,
                "stale config GET audit must send exactly one owner IQ");
        });
    }

    private void test_sequential_members_only_saves_use_updated_baseline() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_membersonly", "boolean", "1");
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "bob", account.full_jid, "none",
                "participant", new Jid("bob@example.test/device")));

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_sequential_members_only_saves.begin(muc_manager, account,
                conversation, stream, (obj, res) => {
                    try {
                        run_sequential_members_only_saves.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "sequential room configuration audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_sequential_members_only_saves(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        Xmpp.Xep.DataForms.DataForm disabled =
            build_members_only_transition_form(true, false);
        Xmpp.Xep.DataForms.DataForm enabled =
            build_members_only_transition_form(false, true);

        MucConfigSaveResult first = yield muc_manager.set_config_form_detailed(
            account, conversation.counterpart, disabled, true);
        if (first != MucConfigSaveResult.APPLIED) {
            throw new IOError.FAILED(
                "first true-to-false configuration was not applied");
        }
        int admin_iqs_after_first = stream.admin_iq_count;
        MucConfigSaveResult second = yield muc_manager.set_config_form_detailed(
            account, conversation.counterpart, enabled, false);
        if (second != MucConfigSaveResult.APPLIED) {
            throw new IOError.FAILED(
                "second false-to-true configuration was not applied");
        }
        if (stream.owner_config_set_count != 2 ||
                stream.owner_config_get_count != 2) {
            throw new IOError.FAILED(
                "two sequential saves must each send one owner SET and one verifying GET");
        }
        if (stream.admin_iq_count != admin_iqs_after_first + 4 ||
                stream.admin_set_count != 1 ||
                stream.admin_set_affiliations.size != 1 ||
                stream.admin_set_affiliations[0] != "member") {
            throw new IOError.FAILED(
                "the second false-to-true save must run membership preflight using the updated baseline");
        }
        if (stream.get_server_config_value_for_tests(
                "muc#roomconfig_membersonly") != "1") {
            throw new IOError.FAILED(
                "the verified server model must retain the second members-only value");
        }
    }

    private void test_members_only_semi_anonymous_sends_no_private_notice() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.disco_members_only = true;
            stream.disco_non_anonymous = false;
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_membersonly", "boolean", "1");
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_whois", "list-single", "anyone");
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);

            var form_node = new StanzaNode.build("x",
                    Xmpp.Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "form")
                .put_node(build_config_field(
                    "muc#roomconfig_membersonly", "boolean", "1"))
                .put_node(build_config_field(
                    "muc#roomconfig_whois", "list-single", "anyone"));
            Xmpp.Xep.DataForms.DataForm form = parse_and_change_config_field(
                form_node, "muc#roomconfig_whois", "moderators");

            MainLoop loop = new MainLoop();
            MucConfigSaveResult? result = null;
            muc_manager.set_config_form_detailed.begin(account,
                conversation.counterpart, form, true, (obj, res) => {
                    result = muc_manager.set_config_form_detailed.end(res);
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);

            fail_if(result == null || (!) result !=
                    MucConfigSaveResult.APPLIED,
                "semi-anonymous members-only configuration must be applied");
            fail_if(muc_manager.is_private_room(account,
                    conversation.counterpart),
                "members-only plus whois=moderators must not be classified as a private DinoX room");
            fail_if(stream.message_count != 0,
                "members-only plus whois=moderators must not emit a false PRIVATE/OMEMO room notice");
            fail_if(stream.owner_config_set_count != 1 ||
                    stream.owner_config_get_count != 1,
                "the semi-anonymous configuration must be confirmed by one owner GET");
        });
    }

    private void test_members_only_rollback_failure_is_not_clean_success() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.owner_config_set_error_condition =
                Xmpp.ErrorStanza.CONDITION_FORBIDDEN;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "bob", account.full_jid, "none",
                "participant", new Jid("bob@example.test/device")));

            Xmpp.Xep.DataForms.DataForm form =
                build_members_only_transition_form(false, true);

            MainLoop loop = new MainLoop();
            bool? saved = null;
            GLib.Test.expect_message("xmpp-vala", LogLevelFlags.LEVEL_WARNING,
                "*Failed to set config form*");
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*Preserving preflight membership*cannot safely compare-and-set a rollback*");
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*configuration was rejected*rollback is incomplete*");
            muc_manager.set_config_form.begin(account,
                conversation.counterpart, form, false, (obj, res) => {
                    saved = muc_manager.set_config_form.end(res);
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            GLib.Test.assert_expected_messages();

            fail_if(saved == null || (!) saved,
                "a rejected config with failed rollback must not report success");
            fail_if(stream.owner_config_set_count != 1,
                "rollback failure audit must reach one rejected config IQ");
            fail_if(stream.admin_set_affiliations.size != 1 ||
                    stream.admin_set_affiliations[0] != "member",
                "rollback safety audit must prove that no destructive compensating IQ was sent");
        });
    }

    private void test_members_only_rollback_preserves_concurrent_promotion() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.owner_config_set_error_condition =
                Xmpp.ErrorStanza.CONDITION_FORBIDDEN;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            Jid bob = new Jid("bob@example.test");
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "bob", account.full_jid, "none",
                "participant", bob.with_resource("device")));

            bool promoted = false;
            stream.owner_config_set_received.connect(() => {
                promoted = true;
                stream.set_server_affiliation_for_tests(bob, "admin");
            });

            Xmpp.Xep.DataForms.DataForm form =
                build_members_only_transition_form(false, true);

            MainLoop loop = new MainLoop();
            bool? saved = null;
            GLib.Test.expect_message("xmpp-vala", LogLevelFlags.LEVEL_WARNING,
                "*Failed to set config form*");
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*Preserving preflight membership*cannot safely compare-and-set a rollback*");
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*configuration was rejected*rollback is incomplete*");
            muc_manager.set_config_form.begin(account,
                conversation.counterpart, form, false, (obj, res) => {
                    saved = muc_manager.set_config_form.end(res);
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            GLib.Test.assert_expected_messages();

            fail_if_not(promoted,
                "the audit must promote the preflight member during config IQ");
            fail_if(saved == null || (!) saved,
                "a rejected config with concurrent promotion must not report success");
            fail_if(stream.get_server_affiliation_for_tests(bob) != "admin",
                "rollback must preserve a concurrent admin promotion");
            foreach (string affiliation in stream.admin_set_affiliations) {
                fail_if(affiliation == "none",
                    "rollback must not send affiliation=none after promotion");
            }
        });
    }

    private void test_config_bookmark_failure_is_not_clean_success() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_membersonly", "boolean", "1");
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_roomsecret", "text-private", "old-secret");

            var provider = new MucManagerAuditBookmarksProvider();
            provider.replace_result = false;
            provider.conferences.add(new Conference() {
                jid = conversation.counterpart,
                nick = conversation.nickname,
                name = "Old name",
                password = "old-secret",
                autojoin = true
            });
            muc_manager.set_bookmarks_provider_for_tests(account, provider);

            var form_node = new StanzaNode.build("x",
                    Xmpp.Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "form")
                .put_node(build_config_field(
                    "muc#roomconfig_membersonly", "boolean", "1"))
                .put_node(build_config_field(
                    "muc#roomconfig_roomsecret", "text-private", "old-secret"));
            Xmpp.Xep.DataForms.DataForm form = parse_and_change_config_field(
                form_node, "muc#roomconfig_roomsecret", "new-secret");

            MainLoop loop = new MainLoop();
            MucConfigSaveResult? result = null;
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*Failed to update MUC bookmark details*");
            muc_manager.set_config_form_detailed.begin(account,
                conversation.counterpart, form, true, (obj, res) => {
                    result = muc_manager.set_config_form_detailed.end(res);
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            GLib.Test.assert_expected_messages();

            fail_if(result == null || (!) result !=
                    MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING,
                "a rejected bookmark replacement after confirmed owner IQ must report an applied local-sync warning");
            fail_if(stream.owner_config_set_count != 1 ||
                    stream.owner_config_get_count != 1 ||
                    provider.get_count != 1 || provider.replace_count != 1,
                "bookmark failure audit must reach the backend exactly once");
            fail_if(provider.last_replacement == null ||
                    ((!) provider.last_replacement).password != "new-secret",
                "bookmark failure audit must carry the configured password");
        });
    }

    private void test_config_disco_failure_still_syncs_verified_bookmark() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.disco_error_condition =
                Xmpp.ErrorStanza.CONDITION_SERVICE_UNAVAILABLE;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_membersonly", "boolean", "1");
            stream.set_server_config_value_for_tests(
                "muc#roomconfig_roomsecret", "text-private", "old-secret");

            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() {
                jid = conversation.counterpart,
                nick = conversation.nickname,
                password = "old-secret",
                autojoin = true
            });
            muc_manager.set_bookmarks_provider_for_tests(account, provider);

            var form_node = new StanzaNode.build("x",
                    Xmpp.Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "form")
                .put_node(build_config_field(
                    "muc#roomconfig_membersonly", "boolean", "1"))
                .put_node(build_config_field(
                    "muc#roomconfig_roomsecret", "text-private", "old-secret"));
            Xmpp.Xep.DataForms.DataForm form = parse_and_change_config_field(
                form_node, "muc#roomconfig_roomsecret", "new-secret");

            MainLoop loop = new MainLoop();
            MucConfigSaveResult? result = null;
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*refreshed room information could not be confirmed*");
            muc_manager.set_config_form_detailed.begin(account,
                conversation.counterpart, form, true, (obj, res) => {
                    result = muc_manager.set_config_form_detailed.end(res);
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            GLib.Test.assert_expected_messages();

            fail_if(result == null || (!) result !=
                    MucConfigSaveResult.APPLIED_LOCAL_SYNC_WARNING,
                "a failed disco refresh after verified SET must report a local-sync warning");
            fail_if(provider.replace_count != 1 ||
                    provider.last_replacement == null ||
                    ((!) provider.last_replacement).password != "new-secret",
                "verified bookmark credentials must still be synchronized when disco refresh fails");
        });
    }

    private delegate bool DeletionTestCompleted();

    private static void wait_deletion_test(DeletionTestCompleted completed) throws Error {
        bool timed_out = false;
        uint timeout = Timeout.add_seconds(5, () => { timed_out = true; return Source.REMOVE; });
        while (!completed() && !timed_out) MainContext.@default().iteration(true);
        if (!timed_out) Source.remove(timeout);
        else throw new IOError.TIMED_OUT("deletion lifecycle test did not finish");
    }

    private void test_contact_history_removal(int variant) {
        with_active_muc((si, account, room) => {
            var stream = prepare_history_audit_stream(si, account, room.counterpart, room.nickname);
            attach_account_module_for_tests<Xmpp.Roster.Module>(si, account, stream, Xmpp.Roster.Module.IDENTITY);
            var manager = si.get_module<ConversationManager>(ConversationManager.IDENTITY);
            var direct = manager.create_conversation(room.counterpart, account, Conversation.Type.CHAT);
            manager.start_conversation(direct);
            var db = get_muc_audit_database();
            si.add_module(new ContentItemStore.for_tests(si, db));
            int direct_item = insert_summary_diagnostic(db, direct, "direct-item");
            int room_item = insert_summary_diagnostic(db, room, "room-item");
            var pm = manager.create_conversation(room.counterpart.with_resource("bob"), account, Conversation.Type.GROUPCHAT_PM);
            int pm_item = insert_summary_diagnostic(db, pm, "pm-item");
            var other = new Account(new Jid("other@example.test"), "secret");
            other.persist(db);
            var other_chat = new Conversation(room.counterpart, other, Conversation.Type.CHAT);
            other_chat.persist(db);
            int other_item = insert_summary_diagnostic(db, other_chat, "other-item");
            var message = new Message("already decrypted local text") {
                account = account, counterpart = room.counterpart, ourpart = account.full_jid,
                type_ = Message.Type.CHAT, direction = Message.DIRECTION_RECEIVED,
                time = new DateTime.now_utc(), local_time = new DateTime.now_utc(),
                encryption = Encryption.OMEMO, marked = Message.Marked.READ
            };
            message.persist(db);
            stream.roster_remove_rejected = variant == 1;
            stream.roster_remove_received.connect(() => {
                if (db.message.select().with<int>(db.message.id, "=", message.id).count() != 1 || !direct.active)
                    error("contact history was deleted before server confirmation");
                if (variant == 2) {
                    manager.forget_conversation(direct);
                    var replacement = manager.create_conversation(room.counterpart, account, Conversation.Type.CHAT);
                    manager.start_conversation(replacement);
                    insert_summary_diagnostic(db, replacement, "replacement-item");
                } else if (variant == 3) {
                    var replacement = new MucManagerAuditStream(stream.remote_name, room.counterpart, room.nickname);
                    var presence = new Xmpp.Presence.Module();
                    replacement.add_module(presence);
                    presence.attach(replacement);
                    si.connection_manager.set_connected_stream_for_tests(account, replacement);
                }
            });
            if (variant == 4) si.connection_manager.disconnect_all();
            bool done = false;
            RosterRemoveResult result = RosterRemoveResult.UNAVAILABLE;
            if (variant == 5) {
                si.get_module<RosterManager>(RosterManager.IDENTITY).remove_jid_async.begin(account, direct.counterpart, (o, r) => {
                    result = si.get_module<RosterManager>(RosterManager.IDENTITY).remove_jid_async.end(r);
                    done = true;
                });
            } else {
                manager.remove_contact_and_history.begin(account, direct.counterpart, (o, r) => {
                    result = manager.remove_contact_and_history.end(r); done = true;
                });
            }
            wait_deletion_test(() => done);
            if (variant == 0) {
                if (result != RosterRemoveResult.SUCCESS || direct.active || direct.history_cleared_at == null ||
                        db.message.select().with<int>(db.message.id, "=", message.id).count() != 0 ||
                        db.content_item.select().with<int>(db.content_item.id, "=", direct_item).count() != 0)
                    throw new IOError.FAILED("successful contact removal did not clear only the selected local chat");
                // Reload the persisted objects, as at startup: the empty record
                // deliberately retains the history floor, not decrypted text.
                bool found = false;
                foreach (Conversation restored in db.get_conversations(account)) {
                    if (restored.id != direct.id) continue;
                    found = true;
                    if (restored.active || restored.history_cleared_at == null)
                        throw new IOError.FAILED("restart lost the deletion boundary");
                }
                if (!found) throw new IOError.FAILED("history tombstone was unexpectedly removed");
            } else {
                RosterRemoveResult expected = variant == 1 ? RosterRemoveResult.SERVER_REJECTED :
                    variant == 5 ? RosterRemoveResult.SUCCESS : RosterRemoveResult.UNAVAILABLE;
                if (result != expected || !direct.active || direct.history_cleared_at != null ||
                        db.message.select().with<int>(db.message.id, "=", message.id).count() != 1 ||
                        db.content_item.select().with<int>(db.content_item.id, "=", direct_item).count() != 1)
                    throw new IOError.FAILED("failed/stale or roster-only removal changed local history");
            }
            foreach (int id in new int[] { room_item, pm_item, other_item }) {
                if (db.content_item.select().with<int>(db.content_item.id, "=", id).count() != 1)
                    throw new IOError.FAILED("contact removal changed a MUC, PM or another account");
            }
        });
    }

    private void test_removed_contact_message(int variant) {
        with_active_muc((si, account, room) => {
            Database db = get_muc_audit_database();
            var processor = si.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
            processor.history_sync.auto_fetch_enabled = false;
            var stream = prepare_history_audit_stream(si, account,
                room.counterpart, room.nickname);
            attach_account_module_for_tests<Xmpp.Roster.Module>(si, account,
                stream, Xmpp.Roster.Module.IDENTITY);
            si.add_module(new ContentItemStore.for_tests(si, db));
            var manager = si.get_module<ConversationManager>(ConversationManager.IDENTITY);
            var direct = manager.create_conversation(new Jid("bob@example.test"),
                account, Conversation.Type.CHAT);
            direct.encryption = Encryption.NONE;
            manager.start_conversation(direct);
            int deleted_item = insert_summary_diagnostic(db, direct, "removed-contact-old");
            var sibling = manager.create_conversation(new Jid("carol@example.test"),
                account, Conversation.Type.CHAT);

            bool done = false;
            RosterRemoveResult result = RosterRemoveResult.UNAVAILABLE;
            manager.remove_contact_and_history.begin(account, direct.counterpart, (obj, res) => {
                result = manager.remove_contact_and_history.end(res);
                done = true;
            });
            wait_deletion_test(() => done);
            if (result != RosterRemoveResult.SUCCESS || direct.active ||
                    direct.history_cleared_at == null)
                throw new IOError.FAILED("fixture must remove and close the contact first");
            DateTime cleared_at = (!) direct.history_cleared_at;

            int activations = 0;
            bool announced = false;
            bool active_at_announcement = false;
            manager.conversation_activated.connect((conversation) => {
                if (conversation == direct) activations++;
            });
            processor.message_received.connect((message, conversation) => {
                if (conversation != direct) return;
                announced = true;
                active_at_announcement = conversation.active;
            });

            if (variant == 4) {
                // Local sends announce through message_sent instead of the
                // received pipeline (which also handles carbon copies).
                processor.message_sent(processor.create_out_message(
                    "new outgoing message", direct), direct);
            } else {
                var stanza = new Xmpp.MessageStanza("removed-contact-new");
                stanza.from = direct.counterpart.with_resource("phone");
                stanza.to = account.full_jid;
                stanza.type_ = Xmpp.MessageStanza.TYPE_CHAT;
                stanza.body = "message after contact removal";
                if (variant != 0) {
                    DateTime? stamp = null;
                    if (variant == 2) stamp = cleared_at.add_seconds(-60);
                    else if (variant == 1) stamp = new DateTime.now_utc();
                    stanza.add_flag(new Xmpp.MessageArchiveManagement.MessageFlag(
                        account.bare_jid, stamp, "removed-contact-archive", "catchup"));
                }
                done = false;
                processor.run_pipeline_announce.begin(account, stanza, (obj, res) => {
                    processor.run_pipeline_announce.end(res);
                    done = true;
                });
                wait_deletion_test(() => done);
            }

            bool should_reopen = variant == 0 || variant == 1 || variant == 4;
            if (variant != 4) {
                int64 stored = db.content_item.select()
                    .with<int>(db.content_item.conversation_id, "=", direct.id)
                    .with<bool>(db.content_item.hide, "=", false).count();
                if (announced != should_reopen || stored != (should_reopen ? 1 : 0))
                    throw new IOError.FAILED("new messages must be stored and announced; cleared or undated MAM must stay deleted");
                if (should_reopen && !active_at_announcement)
                    throw new IOError.FAILED("message was stored and announced to desktop notifications while its chat stayed hidden");
            }
            if (direct.active != should_reopen || activations != (should_reopen ? 1 : 0))
                throw new IOError.FAILED("new incoming or sent messages must reactivate the removed contact's chat exactly once");
            if (direct.history_cleared_at == null ||
                    ((!) direct.history_cleared_at).compare(cleared_at) != 0 ||
                    db.content_item.select().with<int>(db.content_item.id, "=", deleted_item).count() != 0)
                throw new IOError.FAILED("reactivation must preserve the local history deletion boundary");
            if (si.get_module<RosterManager>(RosterManager.IDENTITY)
                    .get_roster_item(account, direct.counterpart) != null || sibling.active || !room.active)
                throw new IOError.FAILED("reactivation must not re-add a roster contact or change other chats");
            foreach (Conversation restored in db.get_conversations(account)) {
                if (restored.id == direct.id && (restored.active != should_reopen ||
                        restored.history_cleared_at == null))
                    throw new IOError.FAILED("chat visibility and the deletion boundary must survive restart");
            }
        });
    }

    private void test_admin_room_destruction(int variant) {
        with_active_muc((si, account, room) => {
            var stream = prepare_history_audit_stream(si, account, room.counterpart, room.nickname);
            stream.advertise_destroy_command = true;
            attach_account_module_for_tests<Xmpp.Xep.AdHocCommands.Module>(si, account, stream, Xmpp.Xep.AdHocCommands.Module.IDENTITY);
            ServerAdministrationManager.start(si);
            var admin = si.get_module<ServerAdministrationManager>(ServerAdministrationManager.IDENTITY);
            var muc = si.get_module<MucManager>(MucManager.IDENTITY);
            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() { jid = room.counterpart, nick = room.nickname, autojoin = true });
            muc.set_bookmarks_provider_for_tests(account, provider);
            var db = get_muc_audit_database();
            int local = insert_summary_diagnostic(db, room, "admin-retained-history");
            long now = (long) new DateTime.now_utc().to_unix();
            int range = insert_history_audit_range(db, account, room.counterpart, "admin-old-room", now - 1000, now);
            var direct = si.get_module<ConversationManager>(ConversationManager.IDENTITY)
                .create_conversation(room.counterpart, account, Conversation.Type.CHAT);
            si.get_module<ConversationManager>(ConversationManager.IDENTITY).start_conversation(direct);
            int direct_item = insert_summary_diagnostic(db, direct, "same-address-chat");
            admin.refresh(account);
            wait_deletion_test(() => admin.get_commands(account).size > 0);
            var command = admin.get_commands(account)[0];
            var form = new Xmpp.Xep.DataForms.DataForm();
            var room_field = new Xmpp.Xep.DataForms.DataForm.Field();
            room_field.var = "room";
            room_field.set_value_string(variant == 7 ? room.counterpart.to_string() :
                variant == 8 ? room.counterpart.localpart.up() : room.counterpart.localpart);
            form.add_field(room_field);
            var service_field = new Xmpp.Xep.DataForms.DataForm.Field();
            service_field.var = "service"; service_field.set_value_string(room.counterpart.domainpart);
            form.add_field(service_field);
            stream.adhoc_error_note = variant == 1;
            stream.adhoc_status = variant == 2 ? "executing" : variant == 3 ? "canceled" : "completed";
            stream.adhoc_wrong_session = variant == 4;
            stream.adhoc_destroy_received.connect(() => {
                if (provider.remove_count != 0 || !room.active)
                    error("admin destruction changed local state before server completion");
                if (variant == 5) {
                    var replacement = new MucManagerAuditStream(stream.remote_name, room.counterpart, room.nickname);
                    var presence = new Xmpp.Presence.Module();
                    replacement.add_module(presence);
                    presence.attach(replacement);
                    si.connection_manager.set_connected_stream_for_tests(account, replacement);
                } else if (variant == 6) {
                    // Create a newer room lifecycle while the older admin
                    // command is still pending. Its completion must not own it.
                    muc.join.begin(account, room.counterpart, room.nickname, null, true, null, true, false, (o, r) => { muc.join.end(r); });
                }
            });
            bool done = false;
            admin.proceed_command.begin(account, command, "destroy-session", "complete", form, (o, r) => {
                admin.proceed_command.end(r); done = true;
            });
            wait_deletion_test(() => done);
            while (MainContext.@default().pending()) MainContext.@default().iteration(false);
            bool should_remove = variant == 0 || variant == 8;
            if (should_remove != !room.active || should_remove != (provider.remove_count == 1) ||
                    should_remove != (db.mam_catchup.select().with<int>(db.mam_catchup.id, "=", range).count() == 0))
                throw new IOError.FAILED("admin completion mishandled local room/bookmark/archive lifecycle");
            if (!direct.active || db.content_item.select().with<int>(db.content_item.id, "=", direct_item).count() != 1 ||
                    db.content_item.select().with<int>(db.content_item.id, "=", local).count() != 1)
                throw new IOError.FAILED("admin room destruction removed local history or same-address direct chat");
        });
    }

    private void test_owner_destroy_presence_before_iq() {
        with_active_muc((si, account, room) => {
            var stream = prepare_history_audit_stream(si, account, room.counterpart, room.nickname);
            var muc = si.get_module<MucManager>(MucManager.IDENTITY);
            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() { jid = room.counterpart, nick = room.nickname, autojoin = true });
            muc.set_bookmarks_provider_for_tests(account, provider);
            establish_owner_context(stream, account, room);
            stream.destroy_iq_received.connect(() => {
                try { stream.emit_presence(build_destroyed_presence(room.counterpart, room.nickname, account.full_jid, false)); }
                catch (Error e) { error("destroy presence fixture: %s", e.message); }
            });
            bool done = false;
            string? failure = null;
            MucDestroyResult? result = null;
            muc.destroy_room_detailed.begin(account, room.counterpart, null, (o, r) => {
                try { result = muc.destroy_room_detailed.end(r); }
                catch (Error e) { failure = e.message; }
                done = true;
            });
            wait_deletion_test(() => done);
            if (failure != null || result != MucDestroyResult.APPLIED || room.active ||
                    muc.is_joined(room.counterpart, account) || provider.remove_count != 1)
                throw new IOError.FAILED("presence before destroy IQ completion repeated or lost teardown: %s".printf(failure ?? "state mismatch"));
        });
    }

    private void test_server_destroy_presence(bool self_status) {
        with_active_muc((si, account, conversation) => {
            var stream = prepare_history_audit_stream(si, account, conversation.counterpart, conversation.nickname);
            var manager = si.get_module<MucManager>(MucManager.IDENTITY);
            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() {
                jid = conversation.counterpart, nick = conversation.nickname, autojoin = true
            });
            manager.set_bookmarks_provider_for_tests(account, provider);
            establish_owner_context(stream, account, conversation);
            var db = get_muc_audit_database();
            long now = (long) new DateTime.now_utc().to_unix();
            insert_history_audit_range(db, account, conversation.counterpart, "destroyed-room", now - 86400, now);
            var sibling = new Jid("other@conference.example.test");
            int sibling_range = insert_history_audit_range(db, account, sibling, "other-room", now - 86400, now);
            int retained_history = insert_summary_diagnostic(db, conversation, "local-history-retained");

            // Another occupant's unavailable stanza is not our room's destruction.
            stream.emit_presence(build_occupant_presence(conversation.counterpart, "bob", account.full_jid));
            stream.emit_presence(build_destroyed_presence(conversation.counterpart, "bob", account.full_jid, false));
            if (!manager.is_joined(conversation.counterpart, account) || !conversation.active || provider.remove_count != 0)
                throw new IOError.FAILED("another occupant's destroy payload retired our room");

            stream.emit_presence(build_destroyed_presence(conversation.counterpart,
                conversation.nickname, account.full_jid, self_status));
            MainContext context = MainContext.@default();
            while (context.pending()) context.iteration(false);
            if (manager.is_joined(conversation.counterpart, account) || conversation.active ||
                    !manager.is_permanent_leave_marked_for_tests(account, conversation.counterpart) ||
                    provider.remove_count != 1)
                throw new IOError.FAILED("server-confirmed destruction left joined/autojoin/bookmark state behind");
            if (db.mam_catchup.select().with<string>(db.mam_catchup.server_jid, "=", conversation.counterpart.to_string()).count() != 0 ||
                    db.mam_catchup.select().with<int>(db.mam_catchup.id, "=", sibling_range).count() != 1)
                throw new IOError.FAILED("destroyed archive coverage survived or another room was changed");
            if (db.content_item.select().with<int>(db.content_item.id, "=", retained_history).count() != 1)
                throw new IOError.FAILED("server room destruction silently deleted local history");
            stream.emit_presence(build_destroyed_presence(conversation.counterpart,
                conversation.nickname, account.full_jid, self_status));
            while (context.pending()) context.iteration(false);
            if (provider.remove_count != 1) throw new IOError.FAILED("duplicate destruction repeated bookmark removal");
        });
    }

    private static StanzaNode build_destroyed_presence(Jid room, string nick, Jid account_jid, bool self_status) throws Error {
        var x = new StanzaNode.build("x", NS_MUC_USER).add_self_xmlns()
            .put_node(new StanzaNode.build("item", NS_MUC_USER).put_attribute("affiliation", "none").put_attribute("role", "none"))
            .put_node(new StanzaNode.build("destroy", NS_MUC_USER)
                .put_node(new StanzaNode.build("reason", NS_MUC_USER).put_node(new StanzaNode.text("Room removed"))));
        if (self_status) x.put_node(new StanzaNode.build("status", NS_MUC_USER).put_attribute("code", "110"));
        return new StanzaNode.build("presence").put_attribute("from", room.with_resource(nick).to_string())
            .put_attribute("to", account_jid.to_string()).put_attribute("type", "unavailable").put_node(x);
    }

    private void test_destroy_rejection_preserves_local_room_state() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            stream.destroy_error_condition = Xmpp.ErrorStanza.CONDITION_FORBIDDEN;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);

            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() {
                jid = conversation.counterpart,
                nick = conversation.nickname,
                autojoin = true
            });
            muc_manager.set_bookmarks_provider_for_tests(account, provider);

            MainLoop loop = new MainLoop();
            string? failure = null;
            muc_manager.destroy_room.begin(account, conversation.counterpart,
                "audit rejection", (obj, res) => {
                    try {
                        muc_manager.destroy_room.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "destroy rejection audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);

            fail_if(failure == null,
                "a rejected destroy IQ must surface an error");
            fail_if(stream.destroy_set_count != 1,
                "destroy rejection audit must send exactly one destroy IQ");
            fail_if(provider.remove_count != 0,
                "bookmark state must remain untouched before destroy confirmation");
            fail_if_not(conversation.active,
                "a rejected destroy IQ must keep the local conversation active");
            fail_if(muc_manager.is_permanent_leave_marked_for_tests(account,
                    conversation.counterpart),
                "a rejected destroy IQ must not install a permanent leave marker");
            fail_if(stream.unavailable_presence_count != 0,
                "a rejected destroy IQ must not leave the live room locally");
        });
    }

    private void test_destroy_stream_change_preserves_new_local_state() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            var replacement = new MucManagerAuditStream(
                new Jid("replacement.example.test"), conversation.counterpart,
                conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            muc_manager.set_muc_occupant_room_generation_for_tests(account,
                conversation.counterpart, 1);
            establish_owner_context(stream, account, conversation);

            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() {
                jid = conversation.counterpart,
                nick = conversation.nickname,
                autojoin = true
            });
            muc_manager.set_bookmarks_provider_for_tests(account, provider);

            bool switched = false;
            stream.received_iq_stanza.connect_after((received_stream, node) => {
                if (switched || stream.last_destroy_iq_id == null ||
                        node.get_attribute("id") != stream.last_destroy_iq_id ||
                        node.get_attribute("type") != Xmpp.Iq.Stanza.TYPE_RESULT) return;
                // The shared IQ handler has accepted this exact successful
                // destroy result; its async continuation has not resumed yet.
                // Replacing earlier would cancel an unconfirmed transaction.
                switched = true;
                try {
                    attach_muc_stream_modules_for_tests(stream_interactor,
                        account, replacement);
                } catch (Error e) {
                    GLib.error("Could not attach replacement destroy audit stream: %s", e.message);
                }
                stream_interactor.connection_manager.set_connected_stream_for_tests(
                    account, replacement);
            });

            MainLoop loop = new MainLoop();
            string? failure = null;
            MucDestroyResult? destroy_result = null;
            muc_manager.destroy_room_detailed.begin(account,
                conversation.counterpart,
                "audit stream change", (obj, res) => {
                    try {
                        destroy_result = muc_manager.destroy_room_detailed.end(
                            res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "destroy stream-change audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);

            fail_if_not(switched,
                "the audit must replace the stream during destroy IQ");
            fail_if(failure != null,
                "a confirmed destroy with superseding lifecycle must complete without deleting it");
            fail_if(destroy_result == null || (!) destroy_result !=
                    MucDestroyResult.APPLIED_LOCAL_SYNC_WARNING,
                "a confirmed destroy whose local cleanup was superseded must report an applied local-sync warning");
            fail_if(provider.remove_count != 0,
                "a stale destroy callback must not remove the newer bookmark state");
            fail_if_not(conversation.active,
                "a stale destroy callback must not close the newer local conversation");
            fail_if(muc_manager.is_permanent_leave_marked_for_tests(account,
                    conversation.counterpart),
                "a stale destroy callback must not mark the newer lifecycle as permanently left");
            fail_if(stream.unavailable_presence_count != 0 ||
                    replacement.unavailable_presence_count != 0,
                "a stale destroy callback must not send exit on either stream");
        });
    }

    private void test_destroy_bookmark_failure_is_not_clean_success() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(
                MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);

            var provider = new MucManagerAuditBookmarksProvider();
            provider.remove_failures_remaining = 1;
            provider.conferences.add(new Conference() {
                jid = conversation.counterpart,
                nick = conversation.nickname,
                autojoin = true
            });
            muc_manager.set_bookmarks_provider_for_tests(account, provider);

            MainLoop loop = new MainLoop();
            string? failure = null;
            MucDestroyResult? result = null;
            GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING,
                "*destroy_room: Server rejected bookmark removal after room destruction*");
            muc_manager.destroy_room_detailed.begin(account,
                conversation.counterpart,
                "audit bookmark failure", (obj, res) => {
                    try {
                        result = muc_manager.destroy_room_detailed.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "destroy bookmark failure audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            GLib.Test.assert_expected_messages();

            fail_if(failure != null,
                "bookmark failure after confirmed destroy must not masquerade as a destroy rejection");
            fail_if(result == null || (!) result !=
                    MucDestroyResult.APPLIED_LOCAL_SYNC_WARNING,
                "bookmark failure after confirmed destroy must report an applied local-sync warning");
            fail_if(stream.destroy_set_count != 1,
                "bookmark failure audit must confirm exactly one destroy IQ");
            fail_if(provider.remove_count < 1,
                "confirmed destruction must attempt bookmark removal");
            fail_if_not(muc_manager.is_permanent_leave_marked_for_tests(account,
                    conversation.counterpart),
                "confirmed destruction must keep the local rejoin block while bookmark retry is owned");
            fail_if(conversation.active,
                "confirmed destruction must close the local conversation even when bookmark sync fails");
            fail_if(stream.unavailable_presence_count != 1,
                "confirmed destruction must leave the local room exactly once");
        });
    }

    private void test_legacy_snapshot_before_remove_confirms_destroy() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            var provider = new MucManagerAuditBookmarksProvider();
            provider.conferences.add(new Conference() {
                jid=conversation.counterpart, nick=conversation.nickname,
                autojoin=true
            });
            provider.emit_snapshot_before_remove_return = true;
            provider.received_conferences.connect((event_stream,
                    conferences) => {
                muc_manager.handle_bookmark_snapshot_for_tests(account,
                    conferences);
            });
            muc_manager.set_bookmarks_provider_for_tests(account, provider);

            MainLoop loop = new MainLoop();
            string? failure = null;
            MucDestroyResult? result = null;
            muc_manager.destroy_room_detailed.begin(account,
                conversation.counterpart, "audit legacy snapshot",
                (obj, res) => {
                    try {
                        result = muc_manager.destroy_room_detailed.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "legacy snapshot destroy audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);

            fail_if(failure != null || result == null || (!) result !=
                    MucDestroyResult.APPLIED || provider.remove_count != 1 ||
                    muc_manager
                        .is_pending_permanent_bookmark_removal_for_tests(
                            account, conversation.counterpart),
                "a legacy pre-return snapshot must not turn a confirmed bookmark remove into a destroy warning");
        });
    }

    private void test_destroy_provider_swap_waits_for_requeued_remove() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname);
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);
            establish_owner_context(stream, account, conversation);
            var stale_provider = new MucManagerAuditBookmarksProvider();
            stale_provider.conferences.add(new Conference() {
                jid=conversation.counterpart, autojoin=true
            });
            stale_provider.defer_next_remove = true;
            muc_manager.set_bookmarks_provider_for_tests(account,
                stale_provider);

            MainLoop loop = new MainLoop();
            string? failure = null;
            MucDestroyResult? result = null;
            muc_manager.destroy_room_detailed.begin(account,
                conversation.counterpart, "audit provider swap",
                (obj, res) => {
                    try {
                        result = muc_manager.destroy_room_detailed.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            drain_muc_audit_context();
            fail_if_not(stale_provider.remove_pending,
                "audit setup must hold the destroy remove on the stale provider");

            var current_provider = new MucManagerAuditBookmarksProvider();
            current_provider.conferences.add(new Conference() {
                jid=conversation.counterpart, autojoin=true
            });
            muc_manager.set_bookmarks_provider_for_tests(account,
                current_provider);
            stale_provider.complete_remove(true);
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "destroy provider-swap audit timed out";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);

            fail_if(failure != null || result == null || (!) result !=
                    MucDestroyResult.APPLIED || stale_provider.remove_count !=
                    1 || current_provider.remove_count != 1 ||
                    muc_manager
                        .is_pending_permanent_bookmark_removal_for_tests(
                            account, conversation.counterpart),
                "destroy must await the requeued current-provider remove instead of reporting a premature warning");
        });
    }

    private void test_visible_muc_prioritizes_autojoin_queue() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            Jid other_room = new Jid("other@conference.example.test");
            Conference selected_candidate = new Conference() {
                jid = conversation.counterpart,
                nick = conversation.nickname,
                autojoin = true
            };
            Conference other_candidate = new Conference() {
                jid = other_room,
                nick = conversation.nickname,
                autojoin = true
            };

            muc_manager.queue_autojoin_candidate_for_tests(account, selected_candidate, true);
            muc_manager.queue_autojoin_candidate_for_tests(account, other_candidate, true);
            Jid? before_priority = muc_manager.peek_autojoin_candidate_for_tests(account);
            fail_if(before_priority == null || !((!) before_priority).equals_bare(other_room),
                "test setup must place another active MUC before the visible room");

            muc_manager.prioritize_conversation_autojoin(conversation);
            Jid? prioritized = muc_manager.peek_autojoin_candidate_for_tests(account);
            fail_if(prioritized == null || !((!) prioritized).equals_bare(conversation.counterpart),
                "the visible MUC must move to the front of the autojoin queue");
            fail_if(muc_manager.autojoin_delay_for_tests(account, 1500) != 0,
                "the visible MUC must not inherit the background autojoin delay");
            fail_if(muc_manager.autojoin_source_priority_for_tests(account) != GLib.Priority.DEFAULT,
                "the visible MUC must not be starved behind low-priority startup work");

            muc_manager.clear_autojoin_queue_for_tests(account);
            muc_manager.prioritize_conversation_autojoin(conversation);
            muc_manager.clear_transient_muc_runtime_state_for_tests(account);
            muc_manager.queue_autojoin_candidate_for_tests(account, selected_candidate, true);
            muc_manager.queue_autojoin_candidate_for_tests(account, other_candidate, true);
            Jid? prioritized_after_discovery = muc_manager.peek_autojoin_candidate_for_tests(account);
            fail_if(prioritized_after_discovery == null ||
                    !((!) prioritized_after_discovery).equals_bare(conversation.counterpart),
                "a visible MUC discovered before later active candidates must remain first");
            fail_if(muc_manager.autojoin_delay_for_tests(account, 1500) != 0,
                "a retained foreground hint must remove the delay after candidate discovery");
            fail_if(muc_manager.autojoin_source_priority_for_tests(account) != GLib.Priority.DEFAULT,
                "a retained foreground hint must survive stream reset with normal priority");

            Conversation other_conversation = new Conversation(other_room, account, Conversation.Type.GROUPCHAT) {
                nickname = conversation.nickname
            };
            muc_manager.prioritize_conversation_autojoin(other_conversation);
            Jid? reprioritized = muc_manager.peek_autojoin_candidate_for_tests(account);
            fail_if(reprioritized == null || !((!) reprioritized).equals_bare(other_room),
                "a later fast selection must replace the previous foreground MUC");

            Conversation direct_chat = new Conversation(new Jid("bob@example.test"), account, Conversation.Type.CHAT);
            muc_manager.prioritize_conversation_autojoin(direct_chat);
            fail_if(muc_manager.autojoin_delay_for_tests(account, 1500) != 1500,
                "selecting a non-MUC must clear the foreground autojoin hint");
            fail_if(muc_manager.autojoin_source_priority_for_tests(account) != GLib.Priority.LOW,
                "background autojoins must retain their low main-loop priority");
            muc_manager.clear_autojoin_queue_for_tests(account);
        });
    }

    private void test_room_observer_routing() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            Jid room = conversation.counterpart.bare_jid;
            Jid other_room = new Jid("other@conference.example.test");
            Jid occupant = room.with_resource("bob");
            Account other_account = new Account(new Jid("other@example.test"), "secret") { id = account.id + 1 };
            int room_info_events = 0;
            int subject_events = 0;
            int private_occupant_events = 0;
            int other_room_events = 0;
            int other_account_events = 0;
            int one_shot_events = 0;
            Jid? delivered_occupant = null;

            MucRoomObserver room_observer = muc_manager.observe_room(account, room,
                (kind, delivered_account, delivered_room, delivered_room_occupant) => {
                    fail_if_not(delivered_account.equals(account), "Room observer must preserve the matching account");
                    fail_if_not(delivered_room.equals_bare(room), "Room observer must normalize delivery to the bare room JID");
                    switch (kind) {
                        case MucRoomUpdateKind.ROOM_INFO:
                            room_info_events++;
                            break;
                        case MucRoomUpdateKind.SUBJECT:
                            subject_events++;
                            break;
                        case MucRoomUpdateKind.PRIVATE_OCCUPANT:
                            private_occupant_events++;
                            delivered_occupant = delivered_room_occupant;
                            break;
                    }
                    return true;
                });
            MucRoomObserver other_room_observer = muc_manager.observe_room(account, other_room,
                (kind, delivered_account, delivered_room, delivered_room_occupant) => {
                    other_room_events++;
                    return true;
                });
            MucRoomObserver other_account_observer = muc_manager.observe_room(other_account, room,
                (kind, delivered_account, delivered_room, delivered_room_occupant) => {
                    other_account_events++;
                    return true;
                });
            muc_manager.observe_room(account, new Jid("one-shot@conference.example.test"),
                (kind, delivered_account, delivered_room, delivered_room_occupant) => {
                    one_shot_events++;
                    return false;
                });

            muc_manager.room_info_updated(account, room.with_resource("ignored"));
            muc_manager.subject_set(account, room, "topic");
            muc_manager.private_room_occupant_updated(account, room, occupant);
            fail_if(room_info_events != 1 || subject_events != 1 || private_occupant_events != 1,
                "Matching room observers must receive each keyed room update kind exactly once");
            fail_if(delivered_occupant == null || !((!) delivered_occupant).equals(occupant),
                "Private-room observer delivery must preserve the occupant JID");
            fail_if(other_room_events != 0 || other_account_events != 0,
                "Room observer delivery must remain isolated by account and bare room JID");

            muc_manager.room_info_updated(account, other_room);
            muc_manager.room_info_updated(other_account, room);
            fail_if(other_room_events != 1 || other_account_events != 1,
                "Room observers must receive only their own account/room updates");
            fail_if(room_info_events != 1,
                "Unrelated account or room updates must not reach the matching-room observer");

            Jid one_shot_room = new Jid("one-shot@conference.example.test");
            muc_manager.room_info_updated(account, one_shot_room);
            muc_manager.subject_set(account, one_shot_room, "second event");
            fail_if(one_shot_events != 1, "A room observer returning false must remove itself after one dispatch");

            room_observer.unsubscribe();
            muc_manager.room_info_updated(account, room);
            fail_if(room_info_events != 1, "Unsubscribed room observers must receive no later events");

            other_room_observer.unsubscribe();
            other_account_observer.unsubscribe();
        });
    }

    private void test_initial_roster_commit() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<MucManager>(MucManager.IDENTITY);
            string[] initial_occupants = { "bob", "carol" };
            string[] unobserved_occupants = { "dora" };
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname,
                initial_occupants, unobserved_occupants);
            attach_muc_stream_modules_for_tests(stream_interactor, account, stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_initial_roster_commit.begin(muc_manager, account, conversation,
                stream, (obj, res) => {
                    try {
                        run_initial_roster_commit.end(res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out waiting for initial roster commit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);

            fail_if(failure != null,
                "initial roster commit audit failed: %s".printf(
                    failure ?? "unknown error"));
        });
    }

    private void test_initial_join_accepts_advertised_occupant_ids() {
        with_active_muc((stream_interactor, account, conversation) => {
            MucManager muc_manager = (!) stream_interactor.get_module<
                MucManager>(MucManager.IDENTITY);
            string[] initial_occupants = { "bob" };
            var stream = new MucManagerAuditStream(new Jid("example.test"),
                conversation.counterpart, conversation.nickname,
                initial_occupants);
            stream.disco_occupant_id = true;
            stream.emit_initial_occupant_ids = true;
            attach_muc_stream_modules_for_tests(stream_interactor, account,
                stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(
                account, stream);

            MainLoop loop = new MainLoop();
            string? failure = null;
            run_initial_join_accepts_advertised_occupant_ids.begin(
                muc_manager, account, conversation, stream, (obj, res) => {
                    try {
                        run_initial_join_accepts_advertised_occupant_ids.end(
                            res);
                    } catch (Error e) {
                        failure = e.message;
                    }
                    loop.quit();
                });
            uint timeout_id = Timeout.add_seconds(5, () => {
                failure = "timed out waiting for advertised occupant-id audit";
                loop.quit();
                return Source.REMOVE;
            });
            loop.run();
            Source.remove(timeout_id);
            fail_if(failure != null,
                "advertised occupant-id audit failed: %s".printf(
                    failure ?? "unknown error"));
        });
    }

    private async void run_initial_join_accepts_advertised_occupant_ids(
            MucManager muc_manager, Account account,
            Conversation conversation, MucManagerAuditStream stream)
            throws Error {
        bool room_info_ready = false;
        var room_info = new Gee.Promise<bool>();
        ulong handler = muc_manager.room_info_updated.connect(
            (delivered_account, room) => {
                if (room_info_ready || !delivered_account.equals(account) ||
                        !room.equals_bare(conversation.counterpart)) return;
                room_info_ready = true;
                room_info.set_value(true);
            });
        try {
            Xmpp.Xep.Muc.JoinResult? result = yield muc_manager.join(account,
                conversation.counterpart, conversation.nickname, null, true);
            validate_join_result(result, "advertised occupant-id MUC join");
            if (!room_info_ready) {
                try {
                    yield room_info.future.wait_async();
                } catch (Gee.FutureError e) {
                    throw new IOError.FAILED(
                        "occupant-id room-info wait failed: %s".printf(
                            e.message));
                }
            }

            Jid bob = conversation.counterpart.with_resource("bob");
            if (!muc_manager.private_message_peer_identity_matches(account,
                    bob, "occupant-id:id-bob")) {
                throw new IOError.FAILED(
                    "an advertised foreign occupant-id received before self-presence must survive initial join");
            }
            if (muc_manager.get_own_occupant_id(account,
                    conversation.counterpart) !=
                    "id-" + conversation.nickname) {
                throw new IOError.FAILED(
                    "an advertised own occupant-id from initial self-presence must be retained");
            }
        } finally {
            SignalHandler.disconnect(muc_manager, handler);
        }
    }

    private async void run_force_rejoin_bypasses_local_join_cache(MucManager muc_manager, Account account, Conversation conversation, MucManagerAuditStream stream) throws Error {
        Xmpp.Xep.Muc.JoinResult? first_join = yield muc_manager.join(account, conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(first_join, "initial MUC join");
        if (stream.join_presence_count != 1) {
            throw new IOError.FAILED("initial join must write exactly one MUC enter presence");
        }

        Xmpp.Xep.Muc.JoinResult? rejoin = yield muc_manager.force_rejoin_for_tests(account, conversation.counterpart, conversation.nickname);
        validate_join_result(rejoin, "forced MUC rejoin");
        if (stream.join_presence_count != 2) {
            throw new IOError.FAILED("forced rejoin must write a second MUC enter presence despite the local joined cache");
        }
    }

    private static void drain_muc_audit_context() {
        MainContext context = MainContext.@default();
        while (context.pending()) context.iteration(false);
    }

    private async void wait_muc_audit_tick() {
        SourceFunc resume = wait_muc_audit_tick.callback;
        Idle.add((owned) resume);
        yield;
    }

    private async void wait_muc_audit_low_tick() {
        SourceFunc resume = wait_muc_audit_low_tick.callback;
        var source = new IdleSource();
        source.set_priority(Priority.LOW + 1);
        source.set_callback((owned) resume);
        source.attach(MainContext.ref_thread_default());
        yield;
    }

    private async void wait_muc_audit_delay(uint milliseconds) {
        SourceFunc resume = wait_muc_audit_delay.callback;
        Timeout.add(milliseconds, (owned) resume);
        yield;
    }

    private async void run_permanent_leave_rejoin_audit(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream,
            MucManagerAuditBookmarksProvider provider,
            bool echo_before_completion) throws Error {
        int removed_signals = 0;
        ulong handler = muc_manager.conference_removed.connect((a, room) => {
            if (a.equals(account) &&
                    room.equals_bare(conversation.counterpart)) {
                removed_signals++;
            }
        });
        try {
            yield muc_manager.leave_permanently(account,
                conversation.counterpart);
            if (!provider.remove_pending || removed_signals != 1) {
                throw new IOError.FAILED(
                    "test setup must hold one old remove after local leave");
            }

            Xmpp.Xep.Muc.Flag? flag = stream.get_flag(
                Xmpp.Xep.Muc.Flag.IDENTITY);
            if (flag == null) throw new IOError.FAILED(
                "test setup missing MUC flag");
            ((!) flag).set_muc_nick(conversation.counterpart.with_resource(
                conversation.nickname));
            Xmpp.Xep.Muc.JoinResult? rejoin = yield muc_manager.join(account,
                conversation.counterpart, conversation.nickname, null, false);
            validate_join_result(rejoin,
                "manual rejoin while old bookmark remove is active");
            if (muc_manager.is_permanent_leave_marked_for_tests(account,
                    conversation.counterpart) ||
                    muc_manager
                        .is_pending_permanent_bookmark_removal_for_tests(
                            account, conversation.counterpart)) {
                throw new IOError.FAILED(
                    "successful manual rejoin must supersede the remove intent");
            }

            if (echo_before_completion) {
                muc_manager.handle_conference_removed_for_tests(account,
                    conversation.counterpart);
                yield wait_muc_audit_tick();
                if (removed_signals != 1) {
                    throw new IOError.FAILED(
                        "a stale retract before its callback must be suppressed");
                }
            }

            provider.complete_remove(true);
            yield wait_muc_audit_tick();
            yield wait_muc_audit_tick();

            bool restored = false;
            foreach (Conference conference in provider.conferences) {
                if (conference.jid != null &&
                        ((!) conference.jid).equals_bare(
                            conversation.counterpart) &&
                        conference.autojoin) {
                    restored = true;
                    break;
                }
            }
            if (!restored || provider.add_count != 1 || !conversation.active) {
                throw new IOError.FAILED(
                    "new rejoin intent must restore the bookmark after stale remove completion");
            }

            if (echo_before_completion) {
                int adds_before_legitimate_remove = provider.add_count;
                muc_manager.handle_conference_removed_for_tests(account,
                    conversation.counterpart);
                yield wait_muc_audit_tick();
                yield wait_muc_audit_tick();
                if (removed_signals != 2 || provider.add_count !=
                        adds_before_legitimate_remove) {
                    throw new IOError.FAILED(
                        "a consumed stale retract must not fence a later legitimate remote remove");
                }
            } else {
                // The PubSub retract may arrive after the old IQ callback and
                // even after the replacement add completed. It still belongs
                // to G1.
                muc_manager.handle_conference_removed_for_tests(account,
                    conversation.counterpart);
                yield wait_muc_audit_tick();
                yield wait_muc_audit_tick();
                if (removed_signals != 1 || !conversation.active) {
                    throw new IOError.FAILED(
                        "a late stale retract must be suppressed and keep the rejoined room active");
                }
            }
        } finally {
            SignalHandler.disconnect(muc_manager, handler);
        }
    }

    private async void run_permanent_remove_echo_before_rejoin_audit(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream,
            MucManagerAuditBookmarksProvider provider,
            bool echo_before_callback) throws Error {
        int removed_signals = 0;
        ulong handler = muc_manager.conference_removed.connect((a, room) => {
            if (a.equals(account) && room.equals_bare(
                    conversation.counterpart)) removed_signals++;
        });
        try {
            yield muc_manager.leave_permanently(account,
                conversation.counterpart);
            if (!provider.remove_pending || removed_signals != 1) {
                throw new IOError.FAILED(
                    "test setup must hold the permanent bookmark remove");
            }
            if (echo_before_callback) {
                muc_manager.handle_conference_removed_for_tests(account,
                    conversation.counterpart);
                yield wait_muc_audit_tick();
            }
            provider.complete_remove(true);
            yield wait_muc_audit_tick();
            yield wait_muc_audit_tick();
            if (!echo_before_callback) {
                muc_manager.handle_conference_removed_for_tests(account,
                    conversation.counterpart);
                yield wait_muc_audit_tick();
            }
            if (removed_signals != 1) {
                throw new IOError.FAILED(
                    "the old retract echo must remain suppressed before rejoin");
            }

            Xmpp.Xep.Muc.Flag? flag = stream.get_flag(
                Xmpp.Xep.Muc.Flag.IDENTITY);
            if (flag == null) throw new IOError.FAILED(
                "test setup missing MUC flag");
            ((!) flag).set_muc_nick(conversation.counterpart.with_resource(
                conversation.nickname));
            Xmpp.Xep.Muc.JoinResult? rejoin = yield muc_manager.join(account,
                conversation.counterpart, conversation.nickname, null, false);
            validate_join_result(rejoin,
                "manual rejoin after completed bookmark remove echo");
            yield wait_muc_audit_tick();
            yield wait_muc_audit_tick();

            bool restored = false;
            foreach (Conference candidate in provider.conferences) {
                if (candidate.jid != null && ((!) candidate.jid).equals_bare(
                        conversation.counterpart) && candidate.autojoin) {
                    restored = true;
                }
            }
            if (!restored || provider.add_count != 1 ||
                    !conversation.active) {
                throw new IOError.FAILED(
                    "rejoin after the consumed old echo must restore the bookmark");
            }

            int adds_before_legitimate_remove = provider.add_count;
            muc_manager.handle_conference_removed_for_tests(account,
                conversation.counterpart);
            yield wait_muc_audit_tick();
            yield wait_muc_audit_tick();
            if (removed_signals != 2 || provider.add_count !=
                    adds_before_legitimate_remove) {
                throw new IOError.FAILED(
                    "consumed pre-rejoin echo provenance must not fence a later legitimate remove");
            }
        } finally {
            SignalHandler.disconnect(muc_manager, handler);
        }
    }

    private async void run_displaced_destroy_remove_waiter_audit(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream,
            MucManagerAuditBookmarksProvider provider) throws Error {
        Xmpp.Xep.Muc.JoinResult? active_write_join = yield muc_manager.join(
            account, conversation.counterpart, conversation.nickname, null,
            false);
        validate_join_result(active_write_join,
            "manual join that starts active bookmark write Gx");
        if (!provider.get_pending) {
            throw new IOError.FAILED(
                "test setup must hold active bookmark write Gx");
        }

        bool destroy_completed = false;
        string? destroy_failure = null;
        MucDestroyResult? destroy_result = null;
        muc_manager.destroy_room_detailed.begin(account,
            conversation.counterpart, "audit displaced waiter", (obj, res) => {
                try {
                    destroy_result = muc_manager.destroy_room_detailed.end(res);
                } catch (Error e) {
                    destroy_failure = e.message;
                }
                destroy_completed = true;
            });
        for (int i = 0; i < 10 && conversation.active; i++) {
            yield wait_muc_audit_tick();
        }
        if (conversation.active || destroy_completed) {
            throw new IOError.FAILED(
                "destroy Gy must wait behind active Gx after local teardown");
        }

        Xmpp.Xep.Muc.Flag? flag = stream.get_flag(
            Xmpp.Xep.Muc.Flag.IDENTITY);
        if (flag == null) throw new IOError.FAILED(
            "test setup missing MUC flag");
        ((!) flag).set_muc_nick(conversation.counterpart.with_resource(
            conversation.nickname));
        Xmpp.Xep.Muc.JoinResult? rejoin = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, false);
        validate_join_result(rejoin,
            "Gz rejoin that displaces pending destroy remove Gy");
        yield wait_muc_audit_tick();
        yield wait_muc_audit_tick();
        if (!destroy_completed || destroy_failure != null ||
                destroy_result == null || (!) destroy_result !=
                    MucDestroyResult.APPLIED_LOCAL_SYNC_WARNING) {
            throw new IOError.FAILED(
                "displaced destroy remove Gy must complete terminally instead of hanging");
        }

        provider.complete_get();
        yield wait_muc_audit_tick();
        yield wait_muc_audit_tick();
    }

    private async void run_part_after_stale_remove_audit(
            MucManager muc_manager, Account account, Conversation conversation,
            MucManagerAuditStream stream,
            MucManagerAuditBookmarksProvider provider,
            bool callback_before_part) throws Error {
        int removed_signals = 0;
        ulong handler = muc_manager.conference_removed.connect((a, room) => {
            if (a.equals(account) && room.equals_bare(
                    conversation.counterpart)) removed_signals++;
        });
        Conference seeded = new Conference() {
            jid=conversation.counterpart, nick=conversation.nickname,
            name="Audit Room", password="audit-secret", autojoin=true
        };
        if (!(yield muc_manager.add_bookmark(account, seeded))) {
            throw new IOError.FAILED("failed to seed desired bookmark metadata");
        }
        yield muc_manager.leave_permanently(account,
            conversation.counterpart);
        if (!provider.remove_pending) {
            throw new IOError.FAILED("test setup must hold the G1 remove");
        }
        Xmpp.Xep.Muc.Flag? flag = stream.get_flag(
            Xmpp.Xep.Muc.Flag.IDENTITY);
        if (flag == null) throw new IOError.FAILED(
            "test setup missing MUC flag");
        ((!) flag).set_muc_nick(conversation.counterpart.with_resource(
            conversation.nickname));
        Xmpp.Xep.Muc.JoinResult? rejoin = yield muc_manager.join(account,
            conversation.counterpart, conversation.nickname, null, false);
        validate_join_result(rejoin, "G2 rejoin before stale remove");
        if (callback_before_part) {
            provider.complete_remove(true);
            yield wait_muc_audit_tick();
            yield wait_muc_audit_tick();
        }
        muc_manager.part(account, conversation.counterpart);
        if (!callback_before_part) provider.complete_remove(true);
        yield wait_muc_audit_tick();
        yield wait_muc_audit_tick();

        Conference? preserved = null;
        foreach (Conference conference in provider.conferences) {
            if (conference.jid != null && ((!) conference.jid).equals_bare(
                    conversation.counterpart)) {
                preserved = conference;
                break;
            }
        }
        if (preserved == null || ((!) preserved).autojoin ||
                ((!) preserved).name != "Audit Room" ||
                ((!) preserved).password != "audit-secret") {
            throw new IOError.FAILED(
                "G3 part must recreate the known bookmark as autojoin=false with metadata " +
                "(present=%s autojoin=%s name=%s password=%s add=%d replace=%d size=%d)".printf(
                    (preserved != null).to_string(),
                    preserved != null ? ((!) preserved).autojoin.to_string() : "n/a",
                    preserved != null ? (((!) preserved).name ?? "null") : "n/a",
                    preserved != null ? (((!) preserved).password ?? "null") : "n/a",
                    provider.add_count, provider.replace_count,
                    provider.conferences.size));
        }

        muc_manager.handle_conference_removed_for_tests(account,
            conversation.counterpart);
        yield wait_muc_audit_tick();
        yield wait_muc_audit_tick();
        bool still_preserved = false;
        foreach (Conference conference in provider.conferences) {
            if (conference.jid != null && ((!) conference.jid).equals_bare(
                    conversation.counterpart) && !conference.autojoin) {
                still_preserved = true;
                break;
            }
        }
        SignalHandler.disconnect(muc_manager, handler);
        if (!still_preserved || removed_signals != 1) {
            throw new IOError.FAILED(
                "a late G1 retract after G3 recreation must be suppressed and repaired");
        }
    }

    private async void run_manual_rejoin_after_leave_bypasses_stale_own_nick(MucManager muc_manager, Account account, Conversation conversation, MucManagerAuditStream stream) throws Error {
        Xmpp.Xep.Muc.JoinResult? first_join = yield muc_manager.join(account, conversation.counterpart, conversation.nickname, null, true);
        validate_join_result(first_join, "initial MUC join");
        if (stream.join_presence_count != 1) {
            throw new IOError.FAILED("initial join must write exactly one MUC enter presence");
        }
        MucRoomKey? first_generation =
            muc_manager.get_room_occupant_generation(account,
                conversation.counterpart);
        if (first_generation == null) {
            throw new IOError.FAILED(
                "initial join must expose its active occupant-cache generation");
        }

        muc_manager.part(account, conversation.counterpart);
        if (stream.unavailable_presence_count != 1) {
            throw new IOError.FAILED("leaving a joined MUC must write one unavailable presence");
        }
        if (muc_manager.get_room_occupant_generation(account,
                conversation.counterpart) != null) {
            throw new IOError.FAILED(
                "leave must revoke the active occupant-cache generation");
        }

        MucRoomDelta? rejoin_snapshot = null;
        var rejoin_snapshot_ready = new Gee.Promise<MucRoomDelta>();
        ulong snapshot_handler = muc_manager.room_occupants_snapshot_ready.connect(
            (delivered_account, room, delta) => {
                if (rejoin_snapshot != null ||
                        !delivered_account.equals(account) ||
                        !room.equals_bare(conversation.counterpart) ||
                        ((!) first_generation).matches(delta.room)) return;
                rejoin_snapshot = delta;
                rejoin_snapshot_ready.set_value(delta);
            });

        try {
            Xmpp.Xep.Muc.Flag? flag = stream.get_flag(Xmpp.Xep.Muc.Flag.IDENTITY);
            if (flag == null) throw new IOError.FAILED("test setup missing MUC flag");
            ((!) flag).set_muc_nick(conversation.counterpart.with_resource(conversation.nickname));

            Xmpp.Xep.Muc.JoinResult? rejoin = yield muc_manager.join(account,
                conversation.counterpart, conversation.nickname, null, false);
            validate_join_result(rejoin, "manual MUC rejoin after leave");
            if (stream.join_presence_count != 2) {
                throw new IOError.FAILED("manual rejoin after leave must write a new enter presence despite stale own nick");
            }
            MucRoomKey? second_generation =
                muc_manager.get_room_occupant_generation(account,
                    conversation.counterpart);
            if (second_generation == null || ((!) first_generation).matches(
                    (!) second_generation)) {
                throw new IOError.FAILED(
                    "same-stream leave/rejoin must expose a distinct occupant-cache generation");
            }

            if (rejoin_snapshot == null) {
                try {
                    rejoin_snapshot = yield rejoin_snapshot_ready.future.wait_async();
                } catch (Gee.FutureError e) {
                    throw new IOError.FAILED(
                        "manual rejoin snapshot wait failed: %s".printf(
                            e.message));
                }
            }
            if (rejoin_snapshot == null ||
                    !((!) rejoin_snapshot).room.matches(
                        (!) second_generation) ||
                    !((!) rejoin_snapshot).full_snapshot ||
                    !((!) rejoin_snapshot).initial_sync_finished ||
                    ((!) rejoin_snapshot).occupant_count == 0) {
                throw new IOError.FAILED(
                    "manual leave/rejoin must retain initial presences and publish a complete snapshot for the new generation");
            }
        } finally {
            SignalHandler.disconnect(muc_manager, snapshot_handler);
        }
    }

    private async void run_initial_roster_commit(MucManager muc_manager,
            Account account, Conversation conversation,
            MucManagerAuditStream stream) throws Error {
        bool sync_started = false;
        bool sync_finished = false;
        int affiliation_events = 0;
        int role_events = 0;
        bool own_role_before_snapshot = false;
        bool roster_events_kept_inside_initial_sync = true;
        MucRoomDelta? delivered_snapshot = null;
        MucRoomDelta? delivered_live_batch = null;
        var finished = new Gee.Promise<bool>();
        var live_batch_finished = new Gee.Promise<bool>();

        ulong started_handler = muc_manager.room_initial_sync_started.connect(
            (delivered_account, room) => {
                if (delivered_account.equals(account) &&
                        room.equals_bare(conversation.counterpart)) {
                    sync_started = true;
                }
            });
        ulong snapshot_handler = muc_manager.room_occupants_snapshot_ready.connect(
            (delivered_account, room, delta) => {
                if (delivered_account.equals(account) &&
                        room.equals_bare(conversation.counterpart)) {
                    delivered_snapshot = delta;
                }
            });
        ulong finished_handler = muc_manager.room_initial_sync_finished.connect(
            (delivered_account, room) => {
                if (!sync_finished && delivered_account.equals(account) &&
                        room.equals_bare(conversation.counterpart)) {
                    sync_finished = true;
                    finished.set_value(true);
                }
            });
        ulong live_batch_handler = muc_manager.room_occupants_changed_batch.connect(
            (delivered_account, room, delta) => {
                if (delivered_live_batch == null &&
                        delivered_account.equals(account) &&
                        room.equals_bare(conversation.counterpart)) {
                    delivered_live_batch = delta;
                    live_batch_finished.set_value(true);
                }
            });
        ulong affiliation_handler = muc_manager.occupant_affiliation_updated.connect(
            (delivered_account, room, occupant, affiliation) => {
                if (delivered_account.equals(account) &&
                        room.equals_bare(conversation.counterpart)) {
                    affiliation_events++;
                    if (!muc_manager.is_initial_presence_sync(account, room)) {
                        roster_events_kept_inside_initial_sync = false;
                    }
                }
            });
        ulong role_handler = muc_manager.received_occupant_role.connect(
            (delivered_account, occupant, role) => {
                if (delivered_account.equals(account) &&
                        occupant.equals_bare(conversation.counterpart)) {
                    role_events++;
                    if (delivered_snapshot == null &&
                            occupant.resourcepart == conversation.nickname) {
                        own_role_before_snapshot = true;
                    }
                    if (!muc_manager.is_initial_presence_sync(account,
                            occupant.bare_jid)) {
                        roster_events_kept_inside_initial_sync = false;
                    }
                }
            });
        try {
            Xmpp.Xep.Muc.JoinResult? result = yield muc_manager.join(account,
                conversation.counterpart, conversation.nickname, null, true);
            validate_join_result(result, "initial roster worker join");
            if (!sync_finished) yield finished.future.wait_async();

            if (!sync_started) {
                throw new IOError.FAILED(
                    "initial roster collection must start without the shadow diagnostics switch");
            }
            if (delivered_snapshot == null) {
                throw new IOError.FAILED(
                    "self-presence 110 must publish one initial roster snapshot");
            }
            MucRoomDelta snapshot = (!) delivered_snapshot;
            if (!snapshot.full_snapshot || !snapshot.initial_sync_finished ||
                    snapshot.degraded_partial || snapshot.occupant_count != 4 ||
                    snapshot.changed_count != 4) {
                throw new IOError.FAILED(
                    "initial roster snapshot must contain captured, reconciled and self occupants exactly once " +
                    "(full=%s finished=%s degraded=%s occupants=%u changed=%u)".printf(
                        snapshot.full_snapshot.to_string(),
                        snapshot.initial_sync_finished.to_string(),
                        snapshot.degraded_partial.to_string(),
                        snapshot.occupant_count, snapshot.changed_count));
            }
            bool found_reconciled_occupant = false;
            for (uint i = 0; i < snapshot.changed_count; i++) {
                MucOccupantSnapshot occupant = snapshot.changed_at(i);
                if (occupant.occupant_full_jid ==
                        conversation.counterpart.to_string() + "/dora") {
                    found_reconciled_occupant = true;
                    if (occupant.affiliation_known || occupant.role_known) {
                        throw new IOError.FAILED(
                            "boundary reconciliation must preserve UNKNOWN role and affiliation state");
                    }
                }
            }
            if (!found_reconciled_occupant) {
                throw new IOError.FAILED(
                    "live PresenceManager membership missing from the parsed event tap must be reconciled before FINISH_ROOM");
            }

            MucRoomDelta? cached = muc_manager.get_room_occupants_snapshot(account,
                conversation.counterpart);
            if (cached == null || ((!) cached).revision != snapshot.revision ||
                    ((!) cached).occupant_count != snapshot.occupant_count) {
                throw new IOError.FAILED(
                    "generation-checked initial roster commit must remain available from MucManager");
            }

            Xmpp.Xep.Muc.Module muc_module = stream.get_module<Xmpp.Xep.Muc.Module>(
                Xmpp.Xep.Muc.Module.IDENTITY);
            if (!muc_module.occupant_presence_events_enabled) {
                throw new IOError.FAILED(
                    "live worker capture must remain active after the initial snapshot commit");
            }
            if (muc_manager.is_initial_presence_sync(account,
                    conversation.counterpart)) {
                throw new IOError.FAILED(
                    "initial sync marker must clear after the bounded compatibility commit");
            }
            if (affiliation_events != 3 || role_events != 3) {
                throw new IOError.FAILED(
                    "initial role and affiliation fanout must be deferred and replayed exactly once");
            }
            if (!own_role_before_snapshot) {
                throw new IOError.FAILED(
                    "the local occupant role must stay on the prompt direct path for moderated input");
            }
            if (!roster_events_kept_inside_initial_sync) {
                throw new IOError.FAILED(
                    "initial compatibility fanout must remain suppressible by status-message consumers");
            }

            int initial_affiliation_events = affiliation_events;
            int initial_role_events = role_events;
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "bob", account.bare_jid,
                "member", "moderator"));
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "bob", account.bare_jid,
                "member", "visitor"));
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "fred", account.bare_jid));
            stream.emit_presence(build_occupant_presence(
                conversation.counterpart, "erin", account.bare_jid));
            stream.emit_presence(build_unavailable_occupant_presence(
                conversation.counterpart, "erin", account.bare_jid));
            if (affiliation_events != initial_affiliation_events ||
                    role_events != initial_role_events) {
                throw new IOError.FAILED(
                    "live per-occupant compatibility signals must stay deferred until the bounded batch flush");
            }
            if (delivered_live_batch == null) {
                yield live_batch_finished.future.wait_async();
            }
            // The batch signal intentionally reaches display consumers before
            // the legacy compatibility fanout in the same main-context turn.
            var compatibility_turn_finished = new Gee.Promise<bool>();
            Idle.add(() => {
                compatibility_turn_finished.set_value(true);
                return Source.REMOVE;
            });
            yield compatibility_turn_finished.future.wait_async();
            if (delivered_live_batch == null) {
                throw new IOError.FAILED(
                    "live occupant changes must publish one bounded batch");
            }
            MucRoomDelta live_delta = (!) delivered_live_batch;
            if (live_delta.full_snapshot || live_delta.degraded_partial ||
                    live_delta.changed_count != 2 ||
                    live_delta.removed_count != 1 ||
                    live_delta.occupant_count != 5) {
                throw new IOError.FAILED(
                    "live batch must coalesce final occupant state exactly once " +
                    "(full=%s degraded=%s changed=%u removed=%u occupants=%u)".printf(
                        live_delta.full_snapshot.to_string(),
                        live_delta.degraded_partial.to_string(),
                        live_delta.changed_count, live_delta.removed_count,
                        live_delta.occupant_count));
            }
            bool found_bob = false;
            bool found_fred = false;
            for (uint i = 0; i < live_delta.changed_count; i++) {
                MucOccupantSnapshot occupant = live_delta.changed_at(i);
                MucOccupantChange flags = live_delta.changed_flags_at(i);
                if (occupant.occupant_full_jid ==
                        conversation.counterpart.to_string() + "/bob") {
                    found_bob = true;
                    if (occupant.role != MucWorkerRoleState.VISITOR ||
                            (flags & MucOccupantChange.ROLE) == 0 ||
                            (flags & MucOccupantChange.MEMBERSHIP) != 0) {
                        throw new IOError.FAILED(
                            "multiple live role changes must collapse to bob's final visitor state");
                    }
                } else if (occupant.occupant_full_jid ==
                        conversation.counterpart.to_string() + "/fred") {
                    found_fred = true;
                    if ((flags & MucOccupantChange.MEMBERSHIP) == 0 ||
                            (flags & MucOccupantChange.AFFILIATION) == 0 ||
                            (flags & MucOccupantChange.ROLE) == 0) {
                        throw new IOError.FAILED(
                            "a final live addition must retain membership, affiliation and role flags");
                    }
                }
            }
            if (!found_bob || !found_fred || live_delta.removed_at(0) !=
                    conversation.counterpart.to_string() + "/erin") {
                throw new IOError.FAILED(
                    "live batch must be deterministic and retain the final removal");
            }
            if (affiliation_events != initial_affiliation_events + 1 ||
                    role_events != initial_role_events + 2) {
                throw new IOError.FAILED(
                    "live compatibility fanout must emit only final changed fields once " +
                    "(affiliation=%d/%d role=%d/%d)".printf(
                        affiliation_events, initial_affiliation_events,
                        role_events, initial_role_events));
            }

            MucRoomDelta? live_cached = muc_manager.get_room_occupants_snapshot(
                account, conversation.counterpart);
            if (live_cached == null || !((!) live_cached).full_snapshot ||
                    ((!) live_cached).revision != live_delta.revision ||
                    ((!) live_cached).occupant_count != 5 ||
                    ((!) live_cached).changed_count != 5) {
                throw new IOError.FAILED(
                    "the display-only full snapshot must rematerialize lazily after a live batch");
            }
            muc_manager.part(account, conversation.counterpart);
            if (muc_manager.get_room_occupants_snapshot(account,
                    conversation.counterpart) != null) {
                throw new IOError.FAILED(
                    "leaving a room must invalidate its display-only worker snapshot");
            }
            if (muc_module.occupant_presence_events_enabled) {
                throw new IOError.FAILED(
                    "leaving the final worker-backed room must stop parsed presence capture");
            }
        } finally {
            SignalHandler.disconnect(muc_manager, started_handler);
            SignalHandler.disconnect(muc_manager, snapshot_handler);
            SignalHandler.disconnect(muc_manager, finished_handler);
            SignalHandler.disconnect(muc_manager, live_batch_handler);
            SignalHandler.disconnect(muc_manager, affiliation_handler);
            SignalHandler.disconnect(muc_manager, role_handler);
        }
    }

    private class SnapshotHoldListener : MessageListener {
        public uint calls = 0;
        private SourceFunc? arrived_callback;
        private SourceFunc? held_callback;
        public override string action_group { get { return "DECRYPT"; } }
        private string[] dependencies = {};
        public override string[] after_actions { get { return dependencies; } }

        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            calls++;
            if (calls == 1) {
                held_callback = run.callback;
                if (arrived_callback != null) Idle.add((owned) arrived_callback);
                yield;
            }
            return false;
        }

        public async void wait_first() {
            if (calls > 0) return;
            arrived_callback = wait_first.callback;
            yield;
        }

        public void release() {
            if (held_callback != null) Idle.add((owned) held_callback);
        }
    }

    // The existing MUC fixture has no UI ContentItemStore. Stop only after
    // the real STORE listener, keeping this test focused on receive drainage.
    private class SnapshotStopAfterStore : MessageListener {
        public signal void stored(string? stanza_id);
        public override string action_group { get { return "MESSAGE_REINTERPRETING"; } }
        private string[] dependencies = { "STORE" };
        public override string[] after_actions { get { return dependencies; } }
        public override async bool run(Entities.Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
            stored(stanza.id);
            return true;
        }
    }

    private void test_snapshot_pipeline_barrier(bool live_cursor) {
        with_active_muc((interactor, account, conversation) => {
            var loop = new MainLoop();
            string? failure = null;
            bool done = false;
            run_snapshot_pipeline_barrier.begin(interactor, account, conversation, live_cursor, (_, result) => {
                try { run_snapshot_pipeline_barrier.end(result); }
                catch (Error e) { failure = e.message; }
                done = true;
                loop.quit();
            });
            uint timeout = 0;
            timeout = Timeout.add_seconds(5, () => {
                timeout = 0;
                failure = "Timed out draining the real message pipeline";
                loop.quit();
                return Source.REMOVE;
            });
            if (!done) loop.run();
            if (timeout != 0) Source.remove(timeout);
            if (failure != null) throw new IOError.FAILED((!) failure);
        });
    }

    private async void run_snapshot_pipeline_barrier(StreamInteractor interactor, Account account,
            Conversation conversation, bool live_cursor) throws Error {
        var processor = interactor.get_module<MessageProcessor>(MessageProcessor.IDENTITY);
        processor.history_sync.auto_fetch_enabled = false;
        var stream = new MucManagerAuditStream(new Jid("example.test"), conversation.counterpart, conversation.nickname);
        attach_muc_stream_modules_for_tests(interactor, account, stream);
        interactor.connection_manager.set_connected_stream_for_tests(account, stream);
        var held_listener = new SnapshotHoldListener();
        processor.received_pipeline.connect(held_listener);
        var stop_listener = new SnapshotStopAfterStore();
        processor.received_pipeline.connect(stop_listener);
        Database database = get_muc_audit_database();
        bool first_done = false;
        bool second_done = false;
        SourceFunc? second_callback = null;
        string? snapshot_path = null;
        if (live_cursor) {
            seed_mam_range_for_tests(account, conversation.counterpart, false);
            var ranges = new Gee.HashMap<Jid, int>(Jid.hash_func, Jid.equals_func);
            foreach (Qlite.Row row in database.mam_catchup.select()
                    .with(database.mam_catchup.account_id, "=", account.id)) {
                ranges[conversation.counterpart] = row[database.mam_catchup.id];
            }
            processor.history_sync.current_catchup_id[account] = ranges;
            stop_listener.stored.connect((stanza_id) => {
                if (stanza_id == "snapshot-first") first_done = true;
                if (stanza_id == "snapshot-second") {
                    second_done = true;
                    if (second_callback != null) Idle.add((owned) second_callback);
                }
            });
        }
        try {
        var first = new Xmpp.MessageStanza("snapshot-first");
        first.from = conversation.counterpart.with_resource("bob");
        first.to = account.full_jid;
        first.type_ = Xmpp.MessageStanza.TYPE_GROUPCHAT;
        first.body = "first snapshot boundary message";
        if (live_cursor) {
            first.stanza.put_node(new StanzaNode.build("stanza-id", Xep.UniqueStableStanzaIDs.NS_URI)
                .put_attribute("by", conversation.counterpart.to_string()).put_attribute("id", "archive-first"));
            stream.get_module<Xmpp.MessageModule>(Xmpp.MessageModule.IDENTITY).received_message(stream, first);
        } else {
            processor.run_pipeline_announce_on_stream.begin(account, stream, first, null, (_, result) => {
                processor.run_pipeline_announce_on_stream.end(result);
                first_done = true;
            });
        }
        yield held_listener.wait_first();

        bool paused = false;
        string? pause_error = null;
        SourceFunc? drained_callback = null;
        processor.pause_for_snapshot.begin(null, (_, result) => {
            try { processor.pause_for_snapshot.end(result); paused = true; }
            catch (Error e) { pause_error = e.message; }
            if (drained_callback != null) Idle.add((owned) drained_callback);
        });
        var second = new Xmpp.MessageStanza("snapshot-second");
        second.from = first.from;
        second.to = account.full_jid;
        second.type_ = Xmpp.MessageStanza.TYPE_GROUPCHAT;
        second.body = "second snapshot boundary message";
        if (live_cursor) {
            second.stanza.put_node(new StanzaNode.build("stanza-id", Xep.UniqueStableStanzaIDs.NS_URI)
                .put_attribute("by", conversation.counterpart.to_string()).put_attribute("id", "archive-second"));
            stream.get_module<Xmpp.MessageModule>(Xmpp.MessageModule.IDENTITY).received_message(stream, second);
        } else {
            processor.run_pipeline_announce_on_stream.begin(account, stream, second, null, (_, result) => {
                processor.run_pipeline_announce_on_stream.end(result);
                second_done = true;
                if (second_callback != null) Idle.add((owned) second_callback);
            });
        }
        yield wait_muc_audit_low_tick();
        if (paused || first_done || second_done || held_listener.calls != 1)
            throw new IOError.FAILED("Receive snapshot did not hold the active and incoming pipelines");
        if (database.query_column_checked("SELECT count(*) FROM message")[0] != "0")
            throw new IOError.FAILED("Held receive listener unexpectedly reached STORE");
        if (live_cursor && database.query_column_checked("SELECT to_id FROM mam_catchup")[0] != "archive-first")
            throw new IOError.FAILED("A message waiting during drain advanced the live archive cursor");

        drained_callback = run_snapshot_pipeline_barrier.callback;
        held_listener.release();
        yield;
        if (!paused || pause_error != null || !first_done || second_done || held_listener.calls != 1 ||
                database.query_column_checked("SELECT count(*) FROM message")[0] != "1")
            throw new IOError.FAILED("Snapshot did not wait until the first pipeline completed STORE");
        if (live_cursor) {
            snapshot_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-cursor-snapshot-" + Uuid.string_random() + ".db");
            database.backup_to((!) snapshot_path);
            var snapshot = Qlite.Database.open_existing((!) snapshot_path, "muc-manager-test");
            try {
                if (snapshot.query_column_checked("SELECT to_id FROM mam_catchup")[0] != "archive-first" ||
                        snapshot.query_column_checked("SELECT count(*) FROM message")[0] != "1" ||
                        snapshot.query_column_checked("SELECT body FROM message")[0] != first.body)
                    throw new IOError.FAILED("Restorable snapshot cursor does not match its stored messages");
            } finally { snapshot.close(); }
        }
        second_callback = run_snapshot_pipeline_barrier.callback;
        processor.resume_after_snapshot();
        yield;
        if (!second_done || held_listener.calls != 2 ||
                database.query_column_checked("SELECT count(*) FROM message")[0] != "2")
            throw new IOError.FAILED("Snapshot resume lost or prematurely admitted the second message");
        if (live_cursor && database.query_column_checked("SELECT to_id FROM mam_catchup")[0] != "archive-second")
            throw new IOError.FAILED("Resumed live message did not advance its archive cursor");
        } finally {
            held_listener.release();
            processor.resume_after_snapshot();
            if (snapshot_path != null) {
                FileUtils.remove((!) snapshot_path);
                FileUtils.remove((!) snapshot_path + "-wal");
                FileUtils.remove((!) snapshot_path + "-shm");
                FileUtils.remove((!) snapshot_path + "-journal");
            }
        }
    }

    private delegate void ActiveMucTest(StreamInteractor stream_interactor, Account account, Conversation conversation) throws Error;

    private void with_active_muc(ActiveMucTest test,
            bool start_avatar_manager = false) {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-muc-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Database? db = null;
        MucManagerTestApplication? application = null;
        StreamInteractor? stream_interactor = null;
        Account? account = null;
        GLib.Application? previous_application = GLib.Application.get_default();

        try {
            cleanup_muc_test_dir(temp_dir, db_path);
            DirUtils.create_with_parents(temp_dir, 0700);

            db = new Database(db_path, "muc-manager-test");
            stream_interactor = new StreamInteractor.for_tests((!) db);
            application = new MucManagerTestApplication((!) db, (!) stream_interactor);
            GLib.Application.set_default((!) application);
            start_muc_test_modules((!) stream_interactor, (!) db);
            if (start_avatar_manager) {
                AvatarManager.start((!) stream_interactor, (!) db,
                    new Security.FileEncryption(
                        "muc-manager-avatar-reconnect-audit"));
            }

            account = new Account(new Jid("alice@example.test"), "secret");
            ((!) account).enabled = true;
            ((!) account).persist((!) db);
            ((!) stream_interactor).module_manager.initialize((!) account);
            ((!) stream_interactor).account_added((!) account);

            ConversationManager conversation_manager = (!) ((!) stream_interactor).get_module<ConversationManager>(ConversationManager.IDENTITY);
            Conversation conversation = conversation_manager.create_conversation(
                new Jid("room@conference.example.test"),
                (!) account,
                Conversation.Type.GROUPCHAT);
            conversation.nickname = "alice";
            conversation_manager.start_conversation(conversation);

            test((!) stream_interactor, (!) account, conversation);
        } catch (Error e) {
            fail_if_reached(@"Unexpected error in MUC manager audit: $(e.message)");
        } finally {
            if (stream_interactor != null) {
                ((!) stream_interactor).connection_manager.disconnect_all();
                if (account != null) ((!) stream_interactor).account_removed((!) account);
                MucManager? muc_manager = ((!) stream_interactor).get_module<MucManager>(MucManager.IDENTITY);
                if (muc_manager != null) ((!) muc_manager).shutdown();
                MainContext context = MainContext.@default();
                while (context.pending()) context.iteration(false);
            }
            if (application != null && GLib.Application.get_default() == (!) application) {
                GLib.Application.set_default(previous_application);
            }
            if (db != null) {
                ((!) db).close();
            }
            cleanup_muc_test_dir(temp_dir, db_path);
        }
    }

    private static void start_muc_test_modules(StreamInteractor stream_interactor, Database db) {
        MessageStorage.start(stream_interactor, db);
        FileTransferStorage.start(stream_interactor, db);
        MessageProcessor.start(stream_interactor, db);
        EntityInfo.start(stream_interactor, db);
        RosterManager.start(stream_interactor, db);
        Calls.start(stream_interactor, db);
        ConversationManager.start(stream_interactor, db);
        PresenceManager.start(stream_interactor, db);
        OccupantIdStore.start(stream_interactor, db);
        MucManager.start(stream_interactor, db);
    }

    private void attach_muc_stream_modules_for_tests(StreamInteractor stream_interactor, Account account, MucManagerAuditStream stream) throws Error {
        var bind_flag = new Xmpp.Bind.Flag();
        bind_flag.my_jid = account.full_jid;
        bind_flag.finished = true;
        stream.add_flag(bind_flag);

        attach_account_module_for_tests<Xmpp.Iq.Module>(stream_interactor, account, stream, Xmpp.Iq.Module.IDENTITY);
        attach_account_module_for_tests<Xmpp.MessageModule>(stream_interactor, account, stream, Xmpp.MessageModule.IDENTITY);
        attach_account_module_for_tests<Xmpp.Presence.Module>(stream_interactor, account, stream, Xmpp.Presence.Module.IDENTITY);
        attach_account_module_for_tests<Xmpp.Xep.ServiceDiscovery.Module>(stream_interactor, account, stream, Xmpp.Xep.ServiceDiscovery.Module.IDENTITY);
        attach_account_module_for_tests<Xmpp.Xep.Muc.Module>(stream_interactor, account, stream, Xmpp.Xep.Muc.Module.IDENTITY);
        attach_account_module_for_tests<Xmpp.Xep.OccupantIds.Module>(stream_interactor, account, stream, Xmpp.Xep.OccupantIds.Module.IDENTITY);
        attach_account_module_for_tests<Xmpp.Xep.Ping.Module>(stream_interactor, account, stream, Xmpp.Xep.Ping.Module.IDENTITY);
    }

    private void attach_account_module_for_tests<T>(StreamInteractor stream_interactor, Account account, MucManagerAuditStream stream, Xmpp.SimpleModuleIdentity identity) throws Error {
        T? module = stream_interactor.module_manager.get_module<T>(account, identity);
        if (module == null) throw new IOError.FAILED("test setup missing XMPP module %s".printf(identity.id));
        var stream_module = (Xmpp.XmppStreamModule) ((!) module);
        stream.add_module(stream_module);
        stream_module.attach(stream);
    }

    private static void validate_join_result(Xmpp.Xep.Muc.JoinResult? result, string context) throws Error {
        if (result == null) throw new IOError.FAILED("%s returned no result".printf(context));
        if (((!) result).muc_error != null) {
            throw new IOError.FAILED("%s failed with MUC error %s".printf(context, (((!) result).muc_error).to_string()));
        }
        if (((!) result).stanza_error != null) {
            throw new IOError.FAILED("%s failed with stanza error %s".printf(context, (((!) result).stanza_error)));
        }
        if (((!) result).nick == null) throw new IOError.FAILED("%s did not confirm a nick".printf(context));
    }

    private static void establish_owner_context(MucManagerAuditStream stream,
            Account account, Conversation conversation) throws Error {
        Xmpp.Xep.Muc.Flag? flag = stream.get_flag(
            Xmpp.Xep.Muc.Flag.IDENTITY);
        if (flag == null) throw new IOError.FAILED(
            "test setup missing MUC flag");
        ((!) flag).set_muc_nick(conversation.counterpart.with_resource(
            conversation.nickname));
        stream.emit_presence(build_self_presence(conversation.counterpart,
            conversation.nickname, account.full_jid, "owner"));
    }

    private static StanzaNode build_self_presence(Jid room, string nick,
            Jid account_jid, string affiliation = "member",
            string role = "participant") throws Error {
        var item = new StanzaNode.build("item", NS_MUC_USER)
            .put_attribute("jid", account_jid.to_string())
            .put_attribute("affiliation", affiliation)
            .put_attribute("role", role);
        var x_node = new StanzaNode.build("x", NS_MUC_USER)
            .add_self_xmlns()
            .put_node(item)
            .put_node(new StanzaNode.build("status", NS_MUC_USER).put_attribute("code", "110"));
        return new StanzaNode.build("presence")
            .put_attribute("from", room.bare_jid.with_resource(nick).to_string())
            .put_attribute("to", account_jid.to_string())
            .put_node(x_node);
    }

    private static StanzaNode build_occupant_presence(Jid room, string nick,
            Jid account_jid, string affiliation = "member",
            string role = "participant",
            Jid? real_jid_override = null,
            string? avatar_hash = null) throws Error {
        Jid real_jid = real_jid_override ??
            new Jid(nick + "@example.test");
        var item = new StanzaNode.build("item", NS_MUC_USER)
            .put_attribute("jid", real_jid.to_string())
            .put_attribute("affiliation", affiliation)
            .put_attribute("role", role);
        var x_node = new StanzaNode.build("x", NS_MUC_USER)
            .add_self_xmlns()
            .put_node(item);
        var presence = new StanzaNode.build("presence")
            .put_attribute("from", room.bare_jid.with_resource(nick).to_string())
            .put_attribute("to", account_jid.to_string())
            .put_node(x_node);
        if (avatar_hash != null) {
            const string vcard_update_ns = "vcard-temp:x:update";
            presence.put_node(new StanzaNode.build("x", vcard_update_ns)
                .add_self_xmlns()
                .put_node(new StanzaNode.build("photo", vcard_update_ns)
                    .put_node(new StanzaNode.text((!) avatar_hash))));
        }
        return presence;
    }

    private static StanzaNode build_anonymous_occupant_presence(Jid room,
            string nick, Jid account_jid) throws Error {
        var item = new StanzaNode.build("item", NS_MUC_USER)
            .put_attribute("affiliation", "none")
            .put_attribute("role", "participant");
        var x_node = new StanzaNode.build("x", NS_MUC_USER)
            .add_self_xmlns()
            .put_node(item);
        return new StanzaNode.build("presence")
            .put_attribute("from",
                room.bare_jid.with_resource(nick).to_string())
            .put_attribute("to", account_jid.to_string())
            .put_node(x_node);
    }

    private static StanzaNode build_unavailable_occupant_presence(Jid room,
            string nick, Jid account_jid) throws Error {
        Jid real_jid = new Jid(nick + "@example.test");
        var item = new StanzaNode.build("item", NS_MUC_USER)
            .put_attribute("jid", real_jid.to_string())
            .put_attribute("affiliation", "member")
            .put_attribute("role", "none");
        var x_node = new StanzaNode.build("x", NS_MUC_USER)
            .add_self_xmlns()
            .put_node(item);
        return new StanzaNode.build("presence")
            .put_attribute("type", Xmpp.Presence.Stanza.TYPE_UNAVAILABLE)
            .put_attribute("from", room.bare_jid.with_resource(nick).to_string())
            .put_attribute("to", account_jid.to_string())
            .put_node(x_node);
    }

    private static StanzaNode build_bare_room_presence(Jid room,
            Jid account_jid) {
        return new StanzaNode.build("presence")
            .put_attribute("from", room.bare_jid.to_string())
            .put_attribute("to", account_jid.to_string());
    }

    private static StanzaNode build_iq_result_for_request(StanzaNode request, StanzaNode payload, Jid account_jid) {
        return new StanzaNode.build("iq")
            .put_attribute("type", "result")
            .put_attribute("id", request.get_attribute("id"))
            .put_attribute("from", request.get_attribute("to"))
            .put_attribute("to", account_jid.to_string())
            .put_node(payload);
    }

    private static StanzaNode build_iq_error_for_request(
            StanzaNode request, string condition, Jid account_jid) {
        return new StanzaNode.build("iq")
            .put_attribute("type", "error")
            .put_attribute("id", request.get_attribute("id"))
            .put_attribute("from", request.get_attribute("to"))
            .put_attribute("to", account_jid.to_string())
            .put_node(new StanzaNode.build("error")
                .put_attribute("type", Xmpp.ErrorStanza.TYPE_CANCEL)
                .put_node(new StanzaNode.build(condition,
                        "urn:ietf:params:xml:ns:xmpp-stanzas")
                    .add_self_xmlns()));
    }

    private static StanzaNode build_disco_info_result_payload(
            bool members_only = false, bool non_anonymous = false,
            int subject_policy = -1, bool occupant_id = false,
            bool semi_anonymous = false, int invite_policy = -1,
            bool mam = false) {
        StanzaNode query = new StanzaNode.build("query", NS_DISCO_INFO)
            .add_self_xmlns()
            .put_node(new StanzaNode.build("identity", NS_DISCO_INFO)
                .put_attribute("category", "conference")
                .put_attribute("type", "text"))
            .put_node(new StanzaNode.build("feature", NS_DISCO_INFO)
                .put_attribute("var", NS_MUC));
        if (members_only) {
            query.put_node(new StanzaNode.build("feature", NS_DISCO_INFO)
                .put_attribute("var", "muc_membersonly"));
        }
        if (non_anonymous) {
            query.put_node(new StanzaNode.build("feature", NS_DISCO_INFO)
                .put_attribute("var", "muc_nonanonymous"));
        }
        if (semi_anonymous) {
            query.put_node(new StanzaNode.build("feature", NS_DISCO_INFO)
                .put_attribute("var", "muc_semianonymous"));
        }
        if (occupant_id) {
            query.put_node(new StanzaNode.build("feature", NS_DISCO_INFO)
                .put_attribute("var", Xmpp.Xep.OccupantIds.NS_URI));
        }
        if (mam) {
            query.put_node(new StanzaNode.build("feature", NS_DISCO_INFO)
                .put_attribute("var",
                    Xmpp.MessageArchiveManagement.NS_URI));
        }
        if (subject_policy >= 0 || invite_policy >= 0) {
            StanzaNode form = new StanzaNode.build("x",
                    Xmpp.Xep.DataForms.NS_URI)
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
            query.put_node(form);
        }
        return query;
    }

    private static StanzaNode build_config_field(string field_var, string field_type, string value) {
        return new StanzaNode.build("field", Xmpp.Xep.DataForms.NS_URI)
            .put_attribute("var", field_var)
            .put_attribute("type", field_type)
            .put_node(new StanzaNode.build("value", Xmpp.Xep.DataForms.NS_URI)
                .put_node(new StanzaNode.text(value)));
    }

    private static Xmpp.Xep.DataForms.DataForm parse_and_change_config_field(
            StanzaNode form_node, string field_var, string value) throws Error {
        Xmpp.Xep.DataForms.DataForm? maybe_form =
            Xmpp.Xep.DataForms.DataForm.create_from_node(form_node);
        if (maybe_form == null) {
            throw new IOError.FAILED(
                "room configuration test form did not parse");
        }
        foreach (Xmpp.Xep.DataForms.DataForm.Field field in
                ((!) maybe_form).fields) {
            if (field.var != field_var) continue;
            field.set_value_string(value);
            return (!) maybe_form;
        }
        throw new IOError.FAILED(
            "room configuration test field %s was missing".printf(field_var));
    }

    private static Xmpp.Xep.DataForms.DataForm
            build_members_only_transition_form(bool original_value,
                                                bool updated_value)
            throws Error {
        var form_node = new StanzaNode.build("x",
                Xmpp.Xep.DataForms.NS_URI)
            .add_self_xmlns()
            .put_attribute("type", "form")
            .put_node(build_config_field(
                "muc#roomconfig_membersonly", "boolean",
                original_value ? "1" : "0"));
        return parse_and_change_config_field(form_node,
            "muc#roomconfig_membersonly", updated_value ? "1" : "0");
    }

    private static Database get_muc_audit_database() throws Error {
        MucManagerTestApplication? application =
            GLib.Application.get_default() as MucManagerTestApplication;
        if (application == null) {
            throw new IOError.FAILED(
                "MUC MAM audit database is unavailable");
        }
        return ((!) application).db;
    }

    private static void seed_mam_range_for_tests(Account account, Jid room,
            bool from_end) throws Error {
        Database db = get_muc_audit_database();
        long now = (long) (new DateTime.now_utc()).to_unix();
        db.mam_catchup.insert()
            .value<int>(db.mam_catchup.account_id, account.id)
            .value<string>(db.mam_catchup.server_jid,
                room.bare_jid.to_string())
            .value<string>(db.mam_catchup.from_id, "existing-first")
            .value<long>(db.mam_catchup.from_time, now - 24 * 60 * 60)
            .value<bool>(db.mam_catchup.from_end, from_end)
            .value<string>(db.mam_catchup.to_id, "existing-last")
            .value<long>(db.mam_catchup.to_time, now)
            .perform();
    }

    private static int get_mam_range_count_for_tests(Account account,
            Jid room) throws Error {
        Database db = get_muc_audit_database();
        return (int) db.mam_catchup.select()
            .with<int>(db.mam_catchup.account_id, "=", account.id)
            .with<string>(db.mam_catchup.server_jid, "=",
                room.bare_jid.to_string())
            .count();
    }

    private static long get_mam_range_from_time_for_tests(Account account,
            Jid mam_server) throws Error {
        Database db = get_muc_audit_database();
        foreach (Qlite.Row row in db.mam_catchup.select()
                .with<int>(db.mam_catchup.account_id, "=", account.id)
                .with<string>(db.mam_catchup.server_jid, "=",
                    mam_server.bare_jid.to_string())) {
            return (long) row[db.mam_catchup.from_time];
        }
        throw new IOError.FAILED(
            "parallel MAM audit did not create a DB range for %s".printf(
                mam_server.bare_jid.to_string()));
    }

    private static void sqlite_exec_or_throw(Sqlite.Database db, string sql) throws Error {
        if (db.exec(sql, null, null) != Sqlite.OK) {
            throw new IOError.FAILED("synthetic v44 SQL failed: %s".printf(db.errmsg()));
        }
    }

    private void cleanup_muc_test_dir(string temp_dir, string db_path) {
        FileUtils.remove(db_path);
        FileUtils.remove(db_path + "-shm");
        FileUtils.remove(db_path + "-wal");
        DirUtils.remove(temp_dir);
    }

    private class MucManagerTestApplication : GLib.Application, Dino.Application {
        public Database db { get; set; }
        public string? db_key { get; set; }
        public Security.FileEncryption file_encryption { get; set; }
        public Dino.Entities.Settings settings { get; set; }
        public StreamInteractor stream_interactor { get; set; }
        public Plugins.Registry plugin_registry { get; set; default = new Plugins.Registry(); }
        public SearchPathGenerator? search_path_generator { get; set; }

        public MucManagerTestApplication(Database db, StreamInteractor stream_interactor) {
            Object(application_id: "im.dinox.muc-manager-audit-test", flags: GLib.ApplicationFlags.NON_UNIQUE);
            this.db = db;
            this.db_key = "muc-manager-test";
            this.file_encryption = new Security.FileEncryption((!) this.db_key);
            this.settings = new Dino.Entities.Settings.from_db(db);
            this.stream_interactor = stream_interactor;
        }

        public void handle_uri(string jid, string query, Gee.Map<string, string> options) {
        }
    }

    private class TestHistorySyncReadinessGate : AccountReadinessGate {
        private bool ready;

        public TestHistorySyncReadinessGate(bool ready) {
            this.ready = ready;
        }

        public override bool is_ready(Account account) {
            return ready;
        }

        public void set_ready(Account account, bool ready) {
            if (this.ready == ready) return;
            this.ready = ready;
            readiness_changed(account);
        }
    }

    private class CountingHistoryPolicyDecryptListener : MessageListener {
        public int calls { get; private set; default = 0; }
        public int last_account_id { get; private set; default = -1; }
        public int last_conversation_id { get; private set; default = -1; }
        private string[] dependencies = new string[] {};

        public CountingHistoryPolicyDecryptListener(bool wait_for_hold = false) {
            if (wait_for_hold) dependencies = new string[] { "HISTORY_POLICY_HOLD" };
        }

        public override string action_group { get { return "DECRYPT"; } }
        public override string[] after_actions { get { return dependencies; } }

        public override async bool run(Entities.Message message,
                Xmpp.MessageStanza stanza, Conversation conversation) {
            if (stanza.stanza.get_subnode("encrypted",
                    "eu.siacs.conversations.axolotl") == null) {
                fail_if_reached("policy audit did not reach DECRYPT with ciphertext");
            }
            calls++;
            last_account_id = message.account.id;
            last_conversation_id = conversation.id;
            // This is a permission-order probe, not a crypto interoperability
            // test. Stop here so the synthetic ciphertext is never stored.
            return true;
        }
    }

    private class HistoryPolicyHoldListener : MessageListener {
        public bool entered { get; private set; default = false; }
        private bool released = false;
        private SourceFunc? continuation = null;
        private string[] dependencies = new string[] {};

        public override string action_group { get { return "HISTORY_POLICY_HOLD"; } }
        public override string[] after_actions { get { return dependencies; } }

        public override async bool run(Entities.Message message,
                Xmpp.MessageStanza stanza, Conversation conversation) {
            entered = true;
            if (!released) {
                continuation = run.callback;
                yield;
            }
            return false;
        }

        public void release() {
            released = true;
            if (continuation != null) Idle.add((owned) continuation);
        }
    }

    private class FlipReadinessOnDecryptListener : MessageListener {
        private TestHistorySyncReadinessGate gate;
        private Account account;

        public string[] after_actions_const = new string[] {};
        public override string action_group { get { return "DECRYPT"; } }
        public override string[] after_actions {
            get { return after_actions_const; }
        }

        public FlipReadinessOnDecryptListener(
                TestHistorySyncReadinessGate gate, Account account) {
            this.gate = gate;
            this.account = account;
        }

        public override async bool run(Entities.Message message,
                Xmpp.MessageStanza stanza, Conversation conversation) {
            gate.set_ready(account, false);
            return false;
        }
    }

    private class MucManagerAuditBookmarksProvider : Object, BookmarksProvider {
        public Gee.Set<Conference> conferences { get; private set; default =
            new Gee.HashSet<Conference>(Conference.hash_func,
                Conference.equals_func); }
        public bool replace_result { get; set; default = true; }
        public bool defer_next_add { get; set; default = false; }
        public bool defer_next_get { get; set; default = false; }
        public bool defer_next_remove { get; set; default = false; }
        public bool get_returns_null { get; set; default = false; }
        public bool emit_snapshot_before_remove_return { get; set;
            default = false; }
        public int remove_failures_remaining { get; set; default = 0; }
        public int add_count { get; private set; default = 0; }
        public int get_count { get; private set; default = 0; }
        public int replace_count { get; private set; default = 0; }
        public int remove_count { get; private set; default = 0; }
        public Conference? last_replacement { get; private set; default = null; }
        public bool add_pending { get { return add_resume != null; } }
        public bool get_pending { get { return get_resume != null; } }
        public bool remove_pending { get { return remove_resume != null; } }

        private SourceFunc? add_resume;
        private SourceFunc? get_resume;
        private SourceFunc? remove_resume;
        private bool deferred_add_result = false;
        private bool deferred_remove_result = false;

        public async Gee.Set<Conference>? get_conferences(XmppStream stream) {
            get_count++;
            if (defer_next_get) {
                defer_next_get = false;
                SourceFunc resume = get_conferences.callback;
                get_resume = (owned) resume;
                yield;
            }
            if (get_returns_null) return null;
            return conferences;
        }

        public void complete_get() {
            SourceFunc? resume = (owned) get_resume;
            if (resume != null) Idle.add((owned) resume);
        }

        public async bool add_conference(XmppStream stream,
                Conference conference) {
            add_count++;
            if (defer_next_add) {
                defer_next_add = false;
                SourceFunc resume = add_conference.callback;
                add_resume = (owned) resume;
                yield;
                if (!deferred_add_result) return false;
            }
            conferences.add(conference);
            return true;
        }

        public void complete_add(bool result) {
            deferred_add_result = result;
            SourceFunc? resume = (owned) add_resume;
            if (resume != null) Idle.add((owned) resume);
        }

        public async bool remove_conference(XmppStream stream,
                Conference conference) {
            remove_count++;
            if (defer_next_remove) {
                defer_next_remove = false;
                SourceFunc resume = remove_conference.callback;
                remove_resume = (owned) resume;
                yield;
                if (!deferred_remove_result) return false;
            }
            if (remove_failures_remaining > 0) {
                remove_failures_remaining--;
                return false;
            }
            if (conference.jid != null) {
                Conference? found = null;
                foreach (Conference candidate in conferences) {
                    if (candidate.jid != null && ((!) candidate.jid).equals_bare(
                            (!) conference.jid)) {
                        found = candidate;
                        break;
                    }
                }
                if (found != null) conferences.remove((!) found);
            }
            if (emit_snapshot_before_remove_return) {
                received_conferences(stream, conferences);
            }
            return true;
        }

        public void complete_remove(bool result) {
            deferred_remove_result = result;
            SourceFunc? resume = (owned) remove_resume;
            if (resume != null) Idle.add((owned) resume);
        }

        public async bool replace_conference(XmppStream stream, Jid muc_jid,
                Conference modified_conference) {
            replace_count++;
            last_replacement = modified_conference;
            if (replace_result) {
                Conference? found = null;
                foreach (Conference candidate in conferences) {
                    if (candidate.jid != null && ((!) candidate.jid)
                            .equals_bare(muc_jid)) {
                        found = candidate;
                        break;
                    }
                }
                if (found != null) conferences.remove((!) found);
                conferences.add(modified_conference);
            }
            return replace_result;
        }
    }

    private class MucManagerAuditStream : XmppStream {
        public int join_presence_count { get; private set; default = 0; }
        public bool defer_join_presence { get; set; default = false; }
        public int unavailable_presence_count { get; private set; default = 0; }
        public int occupant_presence_resync_count { get; private set;
            default = 0; }
        public int owner_config_set_count { get; private set; default = 0; }
        public int owner_config_get_count { get; private set; default = 0; }
        public int destroy_set_count { get; private set; default = 0; }
        public int admin_iq_count { get; private set; default = 0; }
        public int admin_set_count { get; private set; default = 0; }
        public int vcard_get_count { get; private set; default = 0; }
        public int vcard_set_count { get; private set; default = 0; }
        public bool last_vcard_set_had_photo { get; private set;
            default = false; }
        public string? vcard_get_error_condition { get; set;
            default = null; }
        public string? vcard_set_error_condition { get; set;
            default = null; }
        public string? vcard_response_from_override { get; set;
            default = null; }
        public string? fail_query_affiliation { get; set; default = null; }
        public string? fail_set_affiliation { get; set; default = null; }
        public string? owner_config_set_error_condition { get; set; default = null; }
        public string? owner_config_get_error_condition { get; set; default = null; }
        public bool apply_owner_config_set_values { get; set; default = true; }
        public string? destroy_error_condition { get; set; default = null; }
        public bool roster_remove_rejected = false;
        public signal void roster_remove_received();
        public bool advertise_destroy_command = false;
        public bool adhoc_error_note = false;
        public bool adhoc_wrong_session = false;
        public string adhoc_status = "completed";
        public signal void adhoc_destroy_received();

        public string? disco_error_condition { get; set; default = null; }
        public bool disco_members_only { get; set; default = false; }
        public bool disco_non_anonymous { get; set; default = false; }
        public bool disco_semi_anonymous { get; set; default = false; }
        public int disco_subject_policy { get; set; default = -1; }
        public int disco_invite_policy { get; set; default = -1; }
        public bool derive_disco_invite_policy_from_config { get; set;
            default = false; }
        public bool disco_occupant_id { get; set; default = false; }
        public bool disco_mam { get; set; default = false; }
        public string? auto_mam_error_condition { get; set; default = null; }
        public bool defer_disco_info { get; set; default = false; }
        public bool fail_first_disco_info { get; set; default = false; }
        public bool emit_initial_occupant_ids { get; set; default = false; }
        public string? initial_hatted_occupant { get; set; default = null; }
        public Gee.ArrayList<string> admin_set_affiliations { get; private set;
            default = new Gee.ArrayList<string>(); }
        public Gee.ArrayList<string> admin_set_roles { get; private set;
            default = new Gee.ArrayList<string>(); }
        public int message_count { get; private set; default = 0; }
        public int mam_iq_attempt_count { get; private set; default = 0; }
        public int mam_iq_count { get; private set; default = 0; }
        public int disco_iq_count { get; private set; default = 0; }
        public int held_disco_count {
            get { return held_disco_requests.size; }
        }
        public string? last_message_to { get; private set; default = null; }
        public string? last_message_type { get; private set; default = null; }
        public bool last_message_has_muc_user { get; private set; default = false; }
        public string? last_message_subject { get; private set; default = null; }
        private Gee.HashMap<string, Jid> join_target_rooms =
            new Gee.HashMap<string, Jid>();
        private Gee.HashMap<string, string> join_target_nicks =
            new Gee.HashMap<string, string>();
        private string[] initial_occupants;
        private string[] unobserved_occupants;
        private string initial_self_affiliation;
        private string initial_self_role;
        private Gee.HashMap<string, string> server_affiliations =
            new Gee.HashMap<string, string>();
        private Gee.ArrayList<string> server_config_field_order =
            new Gee.ArrayList<string>();
        private Gee.HashMap<string, string> server_config_field_types =
            new Gee.HashMap<string, string>();
        private Gee.HashMap<string, Gee.ArrayList<string>> server_config_values =
            new Gee.HashMap<string, Gee.ArrayList<string>>();
        private Gee.ArrayList<StanzaNode> mam_requests =
            new Gee.ArrayList<StanzaNode>();
        private Gee.ArrayList<StanzaNode> held_disco_requests =
            new Gee.ArrayList<StanzaNode>();

        public signal void affiliation_query_received(string affiliation);
        public signal void admin_set_received();
        public signal void owner_config_get_received();
        public signal void owner_config_set_received();
        public string? last_destroy_iq_id { get; private set; default = null; }
        public signal void destroy_iq_received();
        public signal void message_written();

        public MucManagerAuditStream(Jid remote_name, Jid room, string nick,
                string[]? initial_occupants = null,
                string[]? unobserved_occupants = null,
                string initial_self_affiliation = "member",
                string initial_self_role = "participant") {
            base(remote_name);
            add_joinable_room_for_tests(room, nick);
            this.initial_occupants = initial_occupants ?? new string[0];
            this.unobserved_occupants = unobserved_occupants ?? new string[0];
            this.initial_self_affiliation = initial_self_affiliation;
            this.initial_self_role = initial_self_role;
            set_server_config_value_for_tests("FORM_TYPE", "hidden",
                "http://jabber.org/protocol/muc#roomconfig");
            set_server_config_value_for_tests(
                "muc#roomconfig_membersonly", "boolean", "0");
            set_server_config_value_for_tests(
                "muc#roomconfig_roomdesc", "text-single",
                "Original description");
        }

        public override async void connect() throws IOError {
        }

        public override async void disconnect() throws IOError {
        }

        public void add_joinable_room_for_tests(Jid join_room,
                string join_nick) {
            string target = join_room.bare_jid.to_string() + "/" +
                join_nick;
            join_target_rooms[target] = join_room.bare_jid;
            join_target_nicks[target] = join_nick;
        }

        public void set_server_affiliation_for_tests(Jid jid,
                string affiliation) {
            string target = jid.bare_jid.to_string();
            if (affiliation == "none") {
                server_affiliations.unset(target);
            } else {
                server_affiliations[target] = affiliation;
            }
        }

        public string? get_server_affiliation_for_tests(Jid jid) {
            return server_affiliations[jid.bare_jid.to_string()];
        }

        public void set_server_config_value_for_tests(string field_var,
                string field_type, string value) {
            var values = new Gee.ArrayList<string>();
            values.add(value);
            set_server_config_values(field_var, field_type, values);
        }

        public string? get_server_config_value_for_tests(string field_var) {
            if (!server_config_values.has_key(field_var)) return null;
            Gee.ArrayList<string> values = server_config_values[field_var];
            return values.size > 0 ? values[0] : "";
        }

        private void set_server_config_values(string field_var,
                string field_type, Gee.List<string> values) {
            if (!server_config_field_types.has_key(field_var)) {
                server_config_field_order.add(field_var);
            }
            server_config_field_types[field_var] = field_type;
            var values_copy = new Gee.ArrayList<string>();
            values_copy.add_all(values);
            server_config_values[field_var] = values_copy;
        }

        private void apply_owner_config_submission(StanzaNode query_node) {
            StanzaNode? form_node = query_node.get_subnode("x",
                Xmpp.Xep.DataForms.NS_URI);
            if (form_node == null) return;
            foreach (StanzaNode field_node in ((!) form_node).get_subnodes(
                    "field", Xmpp.Xep.DataForms.NS_URI)) {
                string? field_var = field_node.get_attribute("var");
                if (field_var == null) continue;
                string? submitted_type = field_node.get_attribute("type");
                string? stored_type = server_config_field_types[(!) field_var];
                string field_type = submitted_type ?? stored_type ??
                    "text-single";
                var values = new Gee.ArrayList<string>();
                foreach (StanzaNode value_node in field_node.get_subnodes(
                        "value", Xmpp.Xep.DataForms.NS_URI)) {
                    values.add(value_node.get_string_content() ?? "");
                }
                set_server_config_values((!) field_var, field_type, values);
            }
        }

        private StanzaNode build_owner_config_result_payload() {
            var form_node = new StanzaNode.build("x",
                    Xmpp.Xep.DataForms.NS_URI)
                .add_self_xmlns()
                .put_attribute("type", "form");
            foreach (string field_var in server_config_field_order) {
                var field_node = new StanzaNode.build("field",
                        Xmpp.Xep.DataForms.NS_URI)
                    .put_attribute("var", field_var)
                    .put_attribute("type",
                        server_config_field_types[field_var]);
                if (server_config_values.has_key(field_var)) {
                    foreach (string value in server_config_values[field_var]) {
                        field_node.put_node(new StanzaNode.build("value",
                                Xmpp.Xep.DataForms.NS_URI)
                            .put_node(new StanzaNode.text(value)));
                    }
                }
                form_node.put_node(field_node);
            }
            return new StanzaNode.build("query", NS_MUC_OWNER)
                .add_self_xmlns()
                .put_node(form_node);
        }

        private StanzaNode build_affiliation_result_payload(
                string? requested_affiliation) {
            var query = new StanzaNode.build("query", NS_MUC_ADMIN)
                .add_self_xmlns();
            if (requested_affiliation == null) return query;
            foreach (var entry in server_affiliations.entries) {
                if (entry.value != requested_affiliation) continue;
                query.put_node(new StanzaNode.build("item", NS_MUC_ADMIN)
                    .put_attribute("jid", entry.key)
                    .put_attribute("affiliation", entry.value));
            }
            return query;
        }

        public override async StanzaNode read() throws IOError {
            throw new IOError.NOT_CONNECTED("test stream has no reader");
        }

        public void emit_mam_success(int index) {
            if (index < 0 || index >= mam_requests.size) return;
            StanzaNode fin = new StanzaNode.build("fin",
                    Xmpp.MessageArchiveManagement.NS_URI)
                .add_self_xmlns()
                .put_attribute("complete", "true")
                .put_node(new StanzaNode.build("set",
                    Xmpp.ResultSetManagement.NS_URI).add_self_xmlns());
            emit_iq_result(MucManagerAudit.build_iq_result_for_request(
                mam_requests[index], fin,
                get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
        }

        public void emit_mam_error(int index, string condition) {
            if (index < 0 || index >= mam_requests.size) return;
            emit_iq_result(MucManagerAudit.build_iq_error_for_request(
                mam_requests[index], condition,
                get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
        }

        public int get_mam_iq_count_for_room(Jid room) {
            int count = 0;
            foreach (StanzaNode request in mam_requests) {
                string? to = request.get_attribute("to");
                if (to == room.bare_jid.to_string()) count++;
            }
            return count;
        }

        public StanzaNode get_mam_request_for_tests(int index) throws Error {
            if (index < 0 || index >= mam_requests.size) {
                throw new IOError.FAILED(
                    "requested held MAM query does not exist");
            }
            return mam_requests[index];
        }

        public void emit_mam_page(int index, bool complete) throws Error {
            string archive_id = "audit-archive-%d".printf(index);
            emit_mam_archived_message(index, archive_id,
                "2026-07-18T10:00:00Z");
            emit_mam_fin(index, complete, archive_id);
        }

        public void emit_mam_archived_message(int index, string archive_id,
                string delay_stamp, string? body = null,
                string? from_override = null, string? to_override = null) throws Error {
            if (index < 0 || index >= mam_requests.size) {
                throw new IOError.FAILED(
                    "requested held MAM page does not exist");
            }
            StanzaNode request = mam_requests[index];
            StanzaNode? query = request.get_subnode("query",
                Xmpp.MessageArchiveManagement.NS_URI);
            string? query_id = query != null
                ? ((!) query).get_attribute("queryid") : null;
            string? room = request.get_attribute("to");
            if (query_id == null || room == null) {
                throw new IOError.FAILED(
                    "held MAM request is missing room or query id");
            }

            Jid account_jid = get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid;
            bool account_archive = ((!) room) == account_jid.bare_jid.to_string();
            // Keep generated temporary strings owned until put_attribute has
            // copied them; a mixed literal/concat ternary inside ?? otherwise
            // frees the selected temporary before the fluent argument uses it.
            string forwarded_from;
            if (from_override != null) forwarded_from = (!) from_override;
            else if (account_archive) forwarded_from = "bob@example.test/phone";
            else forwarded_from = new Jid((!) room).with_resource("archivist").to_string();
            string forwarded_to;
            if (to_override != null) forwarded_to = (!) to_override;
            else forwarded_to = account_jid.to_string();
            var inner_message = new StanzaNode.build("message", "jabber:client")
                .add_self_xmlns()
                .put_attribute("from", forwarded_from)
                .put_attribute("to", forwarded_to)
                .put_attribute("type", account_archive ? Xmpp.MessageStanza.TYPE_CHAT : Xmpp.MessageStanza.TYPE_GROUPCHAT);
            if (body != null) {
                inner_message.put_node(new StanzaNode.build("body",
                        "jabber:client")
                    .put_node(new StanzaNode.text((!) body)));
            }
            var forwarded = new StanzaNode.build("forwarded",
                    Xmpp.StanzaForwarding.NS_URI)
                .add_self_xmlns()
                    .put_node(new StanzaNode.build("delay",
                        Xmpp.Xep.DelayedDelivery.NS_URI)
                    .add_self_xmlns()
                    .put_attribute("stamp", delay_stamp))
                .put_node(inner_message);
            received_message_stanza(this, new StanzaNode.build("message")
                .put_attribute("from", (!) room)
                .put_attribute("to", account_jid.to_string())
                .put_attribute("type", account_archive ? Xmpp.MessageStanza.TYPE_CHAT : Xmpp.MessageStanza.TYPE_GROUPCHAT)
                .put_node(new StanzaNode.build("result",
                        Xmpp.MessageArchiveManagement.NS_URI)
                    .add_self_xmlns()
                    .put_attribute("id", archive_id)
                    .put_attribute("queryid", (!) query_id)
                    .put_node(forwarded)));
        }

        public void emit_mam_fin(int index, bool complete,
                string? archive_id, bool error = false) throws Error {
            if (index < 0 || index >= mam_requests.size) {
                throw new IOError.FAILED(
                    "requested held MAM page does not exist");
            }
            StanzaNode request = mam_requests[index];
            Jid account_jid = get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid;
            StanzaNode fin = new StanzaNode.build("fin",
                    Xmpp.MessageArchiveManagement.NS_URI)
                .add_self_xmlns()
                .put_attribute("complete", complete ? "true" : "false");
            var set = new StanzaNode.build("set", Xmpp.ResultSetManagement.NS_URI).add_self_xmlns();
            if (archive_id != null) {
                set.put_node(new StanzaNode.build("first", Xmpp.ResultSetManagement.NS_URI)
                    .put_node(new StanzaNode.text((!) archive_id)));
                set.put_node(new StanzaNode.build("last", Xmpp.ResultSetManagement.NS_URI)
                    .put_node(new StanzaNode.text((!) archive_id)));
            }
            fin.put_node(set);
            StanzaNode response = MucManagerAudit.build_iq_result_for_request(
                request, fin, account_jid);
            if (error) {
                response.set_attribute("type", Xmpp.Stanza.TYPE_ERROR);
                response.put_node(new StanzaNode.build("error")
                    .put_attribute("type", "cancel")
                    .put_node(new StanzaNode.build("service-unavailable",
                        "urn:ietf:params:xml:ns:xmpp-stanzas").add_self_xmlns()));
            }
            emit_iq_result(response);
        }

        public void release_held_disco_successes() {
            var requests = new Gee.ArrayList<StanzaNode>();
            requests.add_all(held_disco_requests);
            held_disco_requests.clear();
            defer_disco_info = false;
            foreach (StanzaNode request in requests) {
                emit_disco_success(request);
            }
        }

        public void release_held_disco_errors(string condition) {
            var requests = new Gee.ArrayList<StanzaNode>();
            requests.add_all(held_disco_requests);
            held_disco_requests.clear();
            defer_disco_info = false;
            foreach (StanzaNode request in requests) {
                emit_iq_result(MucManagerAudit.build_iq_error_for_request(
                    request, condition,
                    get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
            }
        }

        public void emit_next_held_disco_success() throws Error {
            if (held_disco_requests.is_empty) {
                throw new IOError.FAILED(
                    "no held disco request is available");
            }
            emit_disco_success(held_disco_requests.remove_at(0));
        }

        private void emit_disco_success(StanzaNode node) {
            int effective_invite_policy = disco_invite_policy;
            if (derive_disco_invite_policy_from_config) {
                string? configured = get_server_config_value_for_tests(
                    "muc#roomconfig_allowinvites");
                if (configured == "1" || configured == "true") {
                    effective_invite_policy = 1;
                } else if (configured == "0" || configured == "false") {
                    effective_invite_policy = 0;
                } else {
                    effective_invite_policy = -1;
                }
            }
            emit_iq_result(MucManagerAudit.build_iq_result_for_request(
                node, MucManagerAudit.build_disco_info_result_payload(
                    disco_members_only, disco_non_anonymous,
                    disco_subject_policy, disco_occupant_id,
                    disco_semi_anonymous, effective_invite_policy,
                    disco_mam),
                get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
        }

        public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
            if (node.name == "iq" && node.get_subnode("query",
                    Xmpp.MessageArchiveManagement.NS_URI) != null) {
                mam_iq_attempt_count++;
            }
            if (cancellable != null) cancellable.set_error_if_cancelled();

            if (node.name == "message") {
                message_count++;
                last_message_to = node.get_attribute("to");
                last_message_type = node.get_attribute("type");
                last_message_has_muc_user = node.get_subnode("x", NS_MUC_USER) != null;
                StanzaNode? subject = node.get_subnode("subject");
                last_message_subject = subject != null
                    ? ((!) subject).get_string_content() : null;
                message_written();
                return;
            }

            string? presence_target = node.get_attribute("to");
            if (node.name == "presence" && presence_target != null &&
                    join_target_rooms.has_key((!) presence_target)) {
                Jid selected_room = join_target_rooms[(!) presence_target];
                string selected_nick = join_target_nicks[(!) presence_target];
                if (node.get_attribute("type") == Xmpp.Presence.Stanza.TYPE_UNAVAILABLE) {
                    unavailable_presence_count++;
                    return;
                }
                StanzaNode? muc_x = node.get_subnode("x", NS_MUC);
                StanzaNode? history = muc_x != null
                    ? ((!) muc_x).get_subnode("history", NS_MUC) : null;
                if (history != null &&
                        ((!) history).get_attribute("maxchars") == "0") {
                    occupant_presence_resync_count++;
                    return;
                }
                join_presence_count++;
                if (defer_join_presence) return;
                try {
                    emit_presence(MucManagerAudit.build_bare_room_presence(
                        selected_room,
                        get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
                    foreach (string occupant in initial_occupants) {
                        StanzaNode occupant_presence =
                            MucManagerAudit.build_occupant_presence(
                                selected_room, occupant,
                                get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid);
                        if (initial_hatted_occupant == occupant) {
                            occupant_presence.put_node(new StanzaNode.build(
                                    "hats", NS_MUC_HATS)
                                .add_self_xmlns()
                                .put_node(new StanzaNode.build("hat",
                                        NS_MUC_HATS)
                                    .put_attribute("uri",
                                        "urn:xmpp:hats:worker")
                                    .put_attribute("title", "Worker Hat")
                                    .put_attribute("hue", "210")));
                        }
                        if (emit_initial_occupant_ids) {
                            occupant_presence.put_node(new StanzaNode.build(
                                    "occupant-id",
                                    Xmpp.Xep.OccupantIds.NS_URI)
                                .put_attribute("id", "id-" + occupant));
                        }
                        emit_presence(occupant_presence);
                    }
                    foreach (string occupant in unobserved_occupants) {
                        StanzaNode presence_node = MucManagerAudit.build_occupant_presence(
                            selected_room, occupant,
                            get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid);
                        var presence = new Xmpp.Presence.Stanza.from_stanza(
                            presence_node,
                            get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid);
                        get_flag(Xmpp.Presence.Flag.IDENTITY).add_presence(
                            presence);
                    }
                    StanzaNode self_presence =
                        MucManagerAudit.build_self_presence(selected_room,
                            selected_nick,
                            get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid,
                            initial_self_affiliation, initial_self_role);
                    if (emit_initial_occupant_ids) {
                        self_presence.put_node(new StanzaNode.build(
                                "occupant-id",
                                Xmpp.Xep.OccupantIds.NS_URI)
                                .put_attribute("id", "id-" + selected_nick));
                    }
                    emit_presence(self_presence);
                } catch (Error e) {
                    throw new IOError.FAILED("failed to build test self-presence: %s".printf(e.message));
                }
                return;
            }

            if (node.name != "iq") return;
            StanzaNode? vcard_node = node.get_subnode("vCard", NS_VCARD);
            if (vcard_node != null) {
                string? iq_type = node.get_attribute("type");
                StanzaNode response;
                if (iq_type == Xmpp.Iq.Stanza.TYPE_GET) {
                    vcard_get_count++;
                    if (vcard_get_error_condition != null) {
                        response = MucManagerAudit.build_iq_error_for_request(
                            node, (!) vcard_get_error_condition,
                            get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid);
                    } else {
                        response = MucManagerAudit.build_iq_result_for_request(
                            node,
                            new StanzaNode.build("vCard", NS_VCARD)
                                .add_self_xmlns(),
                            get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid);
                    }
                } else {
                    vcard_set_count++;
                    last_vcard_set_had_photo = ((!) vcard_node).get_subnode(
                        "PHOTO", NS_VCARD) != null;
                    if (vcard_set_error_condition != null) {
                        response = MucManagerAudit.build_iq_error_for_request(
                            node, (!) vcard_set_error_condition,
                            get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid);
                    } else {
                        response = MucManagerAudit.build_iq_result_for_request(
                            node,
                            new StanzaNode.build("vCard", NS_VCARD)
                                .add_self_xmlns(),
                            get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid);
                    }
                }
                if (vcard_response_from_override != null) {
                    response.set_attribute("from",
                        (!) vcard_response_from_override);
                }
                emit_iq_result(response);
                return;
            }
            if (node.get_subnode("query", "jabber:iq:roster") != null) {
                roster_remove_received();
                var roster_result = new StanzaNode.build("iq")
                    .put_attribute("id", node.get_attribute("id"))
                    .put_attribute("type", roster_remove_rejected ? "error" : "result")
                    .put_attribute("from", get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid.bare_jid.to_string());
                if (roster_remove_rejected) roster_result.put_node(new StanzaNode.build("error")
                    .put_attribute("type", "cancel")
                    .put_node(new StanzaNode.build("forbidden", "urn:ietf:params:xml:ns:xmpp-stanzas").add_self_xmlns()));
                Idle.add(() => { emit_iq_result(roster_result); return Source.REMOVE; });
                return;
            }
            StanzaNode? command_node = node.get_subnode("command", Xmpp.Xep.AdHocCommands.NS_URI);
            if (advertise_destroy_command && command_node != null) {
                adhoc_destroy_received();
                var payload = new StanzaNode.build("command", Xmpp.Xep.AdHocCommands.NS_URI).add_self_xmlns()
                    .put_attribute("node", command_node.get_attribute("node"))
                    .put_attribute("sessionid", adhoc_wrong_session ? "wrong-session" : command_node.get_attribute("sessionid"))
                    .put_attribute("status", adhoc_status);
                if (adhoc_error_note) payload.put_node(new StanzaNode.build("note", Xmpp.Xep.AdHocCommands.NS_URI)
                    .put_attribute("type", "error").put_node(new StanzaNode.text("Room not removed")));
                var response = MucManagerAudit.build_iq_result_for_request(node, payload, get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid);
                Idle.add(() => { emit_iq_result(response); return Source.REMOVE; });
                return;
            }
            StanzaNode? discovery_items = node.get_subnode("query", Xmpp.Xep.ServiceDiscovery.NS_URI_ITEMS);
            if (advertise_destroy_command && discovery_items != null) {
                var payload = new StanzaNode.build("query", Xmpp.Xep.ServiceDiscovery.NS_URI_ITEMS).add_self_xmlns();
                if (discovery_items.get_attribute("node") == Xmpp.Xep.AdHocCommands.NS_URI) {
                    payload.put_attribute("node", Xmpp.Xep.AdHocCommands.NS_URI);
                    payload.put_node(new StanzaNode.build("item", Xmpp.Xep.ServiceDiscovery.NS_URI_ITEMS)
                        .put_attribute("jid", "example.test").put_attribute("node", "api-commands/destroy_room").put_attribute("name", "Destroy room"));
                }
                var response = MucManagerAudit.build_iq_result_for_request(node, payload, get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid);
                Idle.add(() => { emit_iq_result(response); return Source.REMOVE; });
                return;
            }
            StanzaNode? query_node = node.get_subnode("query", NS_MUC_OWNER);
            StanzaNode? mam_query = node.get_subnode("query",
                Xmpp.MessageArchiveManagement.NS_URI);
            if (mam_query != null) {
                mam_iq_count++;
                mam_requests.add(node);
                if (auto_mam_error_condition != null) {
                    emit_mam_error(mam_requests.size - 1,
                        (!) auto_mam_error_condition);
                }
                return;
            }
            if (query_node != null && node.get_attribute("type") == "get") {
                owner_config_get_count++;
                owner_config_get_received();
                if (owner_config_get_error_condition != null) {
                    emit_iq_result(MucManagerAudit.build_iq_error_for_request(
                        node, (!) owner_config_get_error_condition,
                        get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
                    return;
                }
                emit_iq_result(MucManagerAudit.build_iq_result_for_request(
                    node, build_owner_config_result_payload(),
                    get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
                return;
            }
            if (query_node != null && node.get_attribute("type") == "set") {
                if (((!) query_node).get_subnode("destroy", NS_MUC_OWNER) != null) {
                    destroy_set_count++;
                    last_destroy_iq_id = node.get_attribute("id");
                    destroy_iq_received();
                    if (destroy_error_condition != null) {
                        emit_iq_result(MucManagerAudit.build_iq_error_for_request(
                            node, (!) destroy_error_condition,
                            get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
                    } else {
                        emit_iq_result(MucManagerAudit.build_iq_result_for_request(
                            node,
                            new StanzaNode.build("query", NS_MUC_OWNER)
                                .add_self_xmlns(),
                            get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
                    }
                    return;
                }
                owner_config_set_count++;
                owner_config_set_received();
                if (owner_config_set_error_condition != null) {
                    emit_iq_result(MucManagerAudit.build_iq_error_for_request(
                        node, (!) owner_config_set_error_condition,
                        get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
                } else {
                    if (apply_owner_config_set_values) {
                        apply_owner_config_submission((!) query_node);
                    }
                    emit_iq_result(MucManagerAudit.build_iq_result_for_request(
                        node,
                        new StanzaNode.build("query", NS_MUC_OWNER).add_self_xmlns(),
                        get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
                }
                return;
            }
            query_node = node.get_subnode("query", NS_DISCO_INFO);
            if (query_node != null) {
                disco_iq_count++;
                if (fail_first_disco_info && disco_iq_count == 1) {
                    emit_iq_result(MucManagerAudit.build_iq_error_for_request(
                        node,
                        Xmpp.ErrorStanza.CONDITION_SERVICE_UNAVAILABLE,
                        get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
                    return;
                }
                if (defer_disco_info) {
                    held_disco_requests.add(node);
                    return;
                }
                if (disco_error_condition != null) {
                    emit_iq_result(MucManagerAudit.build_iq_error_for_request(
                        node, (!) disco_error_condition,
                        get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
                    return;
                }
                emit_disco_success(node);
                return;
            }

            query_node = node.get_subnode("query", NS_MUC_ADMIN);
            if (query_node != null) {
                admin_iq_count++;
                if (node.get_attribute("type") == "set") {
                    admin_set_count++;
                    admin_set_received();
                    StanzaNode? item = ((!) query_node).get_subnode("item", NS_MUC_ADMIN);
                    string? affiliation = item != null
                        ? ((!) item).get_attribute("affiliation") : null;
                    string? role = item != null
                        ? ((!) item).get_attribute("role") : null;
                    string? target = item != null
                        ? ((!) item).get_attribute("jid") : null;
                    if (affiliation != null) admin_set_affiliations.add((!) affiliation);
                    if (role != null) admin_set_roles.add((!) role);
                    if (affiliation != null && fail_set_affiliation ==
                            affiliation) {
                        emit_iq_result(MucManagerAudit.build_iq_error_for_request(
                            node, Xmpp.ErrorStanza.CONDITION_FORBIDDEN,
                            get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
                        return;
                    }
                    if (affiliation != null && target != null) {
                        try {
                            set_server_affiliation_for_tests(
                                new Jid((!) target), (!) affiliation);
                        } catch (InvalidJidError e) {
                            throw new IOError.FAILED(
                                "invalid affiliation target in test IQ");
                        }
                    }
                } else if (fail_query_affiliation != null) {
                    StanzaNode? item = ((!) query_node).get_subnode("item",
                        NS_MUC_ADMIN);
                    string? affiliation = item != null
                        ? ((!) item).get_attribute("affiliation") : null;
                    if (affiliation != null) {
                        affiliation_query_received((!) affiliation);
                    }
                    if (affiliation != null && affiliation ==
                            fail_query_affiliation) {
                        emit_iq_result(MucManagerAudit.build_iq_error_for_request(
                            node, Xmpp.ErrorStanza.CONDITION_FORBIDDEN,
                            get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
                        return;
                    }
                } else {
                    StanzaNode? item = ((!) query_node).get_subnode("item",
                        NS_MUC_ADMIN);
                    string? affiliation = item != null
                        ? ((!) item).get_attribute("affiliation") : null;
                    if (affiliation != null) {
                        affiliation_query_received((!) affiliation);
                    }
                }
                StanzaNode? item = ((!) query_node).get_subnode("item",
                    NS_MUC_ADMIN);
                string? requested_affiliation = item != null
                    ? ((!) item).get_attribute("affiliation") : null;
                emit_iq_result(MucManagerAudit.build_iq_result_for_request(node,
                    build_affiliation_result_payload(requested_affiliation),
                    get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid));
            }
        }

        public void emit_iq_result(StanzaNode node) {
            received_iq_stanza(this, node);
        }

        public void emit_presence(StanzaNode node) {
            received_presence_stanza(this, node);
        }

        public override async void setup() throws IOError {
        }
    }
}

}
