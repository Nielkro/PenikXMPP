using Gee;
using Xmpp;

namespace Dino.Test {

/**
 * Stream lifecycle contract test.
 *
 * Verifies GIO stream contract used by file upload:
 *   - MemoryInputStream.is_closed() == false initially
 *   - close() must succeed without exception
 *   - is_closed() == true after close()
 *
 * Regression guard for issue #1764 (upload error stream leak).
 */
class FileManagerTest : Gee.TestCase {
    private static bool custom_delete_invoked = false;
    private const string NS_JET = "urn:xmpp:jingle:jet:0";
    private const string NS_TEST_JET_TYPE = "urn:xmpp:test:jet-envelope";
    private const string NS_TEST_JET_CIPHER = "urn:xmpp:test:xor-stream";
    private const int64 LARGE_STREAM_BYTES = 1024 * 1024 + 333;

    public FileManagerTest() {
        base("FileManagerTest");
        add_test("GIO_stream_close_lifecycle", test_stream_close);
        add_test("PrefixSniffingInputStream_captures_prefix_across_reads", test_prefix_sniffing_stream_captures_prefix);
        add_test("PrefixSniffingInputStream_counts_all_passed_bytes", test_prefix_sniffing_stream_counts_all_passed_bytes);
        add_test("PrefixSniffingInputStream_returns_copy", test_prefix_sniffing_stream_returns_copy);
        add_test("FileManager_hashes_match_standard_base64", test_hashes_match_standard_base64);
        add_test("FileManager_hashes_match_url_safe_base64", test_hashes_match_url_safe_base64);
        add_test("FileManager_hashes_match_unpadded_expected", test_hashes_match_unpadded_expected);
        add_test("FileManager_hashes_match_rejects_mismatch", test_hashes_match_rejects_mismatch);
        add_test("FileManager_compute_file_hashes_preserves_xep_base64", test_compute_file_hashes_preserves_xep_base64_sync);
        add_test("FileManager_compute_file_hashes_sync_cancelled_returns_no_hashes", test_compute_file_hashes_sync_cancelled_returns_no_hashes);
        add_test("FileManager_generic_metadata_omits_hashes_on_hash_read_error", test_generic_metadata_omits_hashes_on_hash_read_error_sync);
        add_test("FileManager_image_metadata_decodes_off_main_thread", test_image_metadata_decodes_off_main_thread_sync);
        add_test("FileManager_image_metadata_rejects_unsafe_optional_previews", test_image_metadata_rejects_unsafe_optional_previews_sync);
        add_test("MessageStorage_chat_server_id_lookup_handles_resourceful_sender", test_message_storage_chat_server_id_lookup_handles_resourceful_sender);
        add_test("FileManager_incoming_shell_applies_mime_for_decryptor_classification", test_incoming_shell_applies_mime_for_decryptor_classification);
        add_test("FileManager_registered_decryptor_selected_from_provider_mime_on_incoming_classification", test_registered_decryptor_selected_from_provider_mime_on_incoming_classification);
        add_test("FileManager_download_source_uses_provider_liveness", test_download_source_uses_provider_liveness);
        add_test("FileManager_late_provider_mime_classifies_registered_decryptor", test_late_provider_mime_classifies_registered_decryptor_sync);
        add_test("FileManager_late_provider_classification_preserves_existing_encryption", test_late_provider_classification_preserves_existing_encryption_sync);
        add_test("FileManager_verify_and_commit_received_file_rejects_hash_mismatch_before_publish", test_verify_and_commit_rejects_hash_mismatch_sync);
        add_test("FileManager_receive_metadata_cancel_keeps_transfer_unpublished", test_receive_metadata_cancel_keeps_transfer_unpublished_sync);
        add_test("FileManager_receive_store_cancel_cleans_pending_before_publish", test_receive_store_cancel_cleans_pending_before_publish_sync);
        add_test("FileManager_receive_store_hash_mismatch_cleans_pending_before_publish", test_receive_store_hash_mismatch_cleans_pending_before_publish_sync);
        add_test("FileManager_receive_store_empty_media_cleans_pending_before_publish", test_receive_store_empty_media_cleans_pending_before_publish_sync);
        add_test("FileManager_receive_store_accepts_worker_readable_async_only_stream", test_receive_store_accepts_worker_readable_async_only_stream_sync);
        add_test("FileManager_receive_store_worker_readable_async_only_cancel_cleans_pending", test_receive_store_worker_readable_async_only_cancel_cleans_pending_sync);
        add_test("FileManager_receive_store_large_stream_bounded_chunks", test_receive_store_large_stream_bounded_chunks_sync);
        add_test("FileManager_incoming_jingle_ibb_provider_auto_downloads_worker_readable_stream", test_incoming_jingle_ibb_provider_auto_downloads_worker_readable_stream_sync);
        add_test("FileManager_incoming_jingle_s5b_provider_auto_downloads_receive_store", test_incoming_jingle_s5b_provider_auto_downloads_receive_store_sync);
        add_test("FileManager_incoming_jingle_s5b_jet_provider_auto_downloads_receive_store", test_incoming_jingle_s5b_jet_provider_auto_downloads_receive_store_sync);
        add_test("FileManager_incoming_jingle_s5b_jet_auth_failure_keeps_transfer_unpublished", test_incoming_jingle_s5b_jet_auth_failure_keeps_transfer_unpublished_sync);
        add_test("FileManager_incoming_jingle_s5b_account_proxy_activation_auto_downloads_receive_store", test_incoming_jingle_s5b_account_proxy_activation_auto_downloads_receive_store_sync);
        add_test("FileManager_incoming_jingle_s5b_account_proxy_auto_downloads_receive_store", test_incoming_jingle_s5b_account_proxy_auto_downloads_receive_store_sync);
        add_test("FileManager_incoming_jingle_s5b_real_tor_onion_auto_downloads_receive_store", test_incoming_jingle_s5b_real_tor_onion_auto_downloads_receive_store_sync);
        add_test("FileManager_receive_plain_stream_failure_cleans_pending_before_publish", test_receive_plain_stream_failure_cleans_pending_before_publish_sync);
        add_test("FileManager_receive_decrypt_failure_cleans_encrypted_download_before_store", test_receive_decrypt_failure_cleans_encrypted_download_before_store_sync);
        add_test("FileManager_receive_stream_decrypt_failure_cleans_pending_before_publish", test_receive_stream_decrypt_failure_cleans_pending_before_publish_sync);
        add_test("FileManager_auto_download_transport_failure_keeps_manual_retry_available", test_auto_download_transport_failure_keeps_manual_retry_available_sync);
        add_test("FileManager_localized_timeout_schedules_retry", test_localized_timeout_schedules_retry_sync);
        add_test("FileManager_jingle_missing_live_source_is_not_downloadable", test_jingle_missing_live_source_is_not_downloadable);
        add_test("FileManager_download_file_resolves_groupchat_pm_conversation", test_download_file_resolves_groupchat_pm_conversation_sync);
        add_test("FileManager_verify_and_commit_collision_keeps_metadata_unpublished", test_verify_and_commit_collision_keeps_metadata_unpublished_sync);
        add_test("FileManager_unconstrained_file_encryptor_accepts_any_sender", test_unconstrained_file_encryptor_accepts_any_sender);
        add_test("FileManager_file_encryptor_sender_requirement_blocks_jingle", test_file_encryptor_sender_requirement_blocks_jingle);
        add_test("FileManager_file_encryptor_rejection_reason_fails_before_slot", test_file_encryptor_rejection_reason_fails_before_slot_sync);
        add_test("FileManager_file_encryptor_rejection_reason_does_not_mask_no_sender", test_file_encryptor_rejection_reason_does_not_mask_no_sender_sync);
        add_test("FileManager_external_file_encryptor_meta_fails_closed", test_external_file_encryptor_meta_fails_closed);
        add_test("FileManager_external_encryptor_runs_before_slot_prepare", test_external_encryptor_runs_before_slot_prepare_sync);
        add_test("FileManager_unmarked_external_encryptor_meta_never_requests_slot", test_unmarked_external_encryptor_meta_never_requests_slot_sync);
        add_test("FileManager_direct_sender_uses_original_meta_without_external_encryptor", test_direct_sender_uses_original_meta_without_external_encryptor_sync);
        add_test("FileManager_auto_sender_keeps_default_priority", test_auto_sender_keeps_default_priority_sync);
        add_test("FileManager_preferred_sender_overrides_default_priority", test_preferred_sender_overrides_default_priority_sync);
        add_test("FileManager_preferred_sender_does_not_fallback", test_preferred_sender_does_not_fallback_sync);
        add_test("FileManager_CONCURRENCY_mixed_http_jingle_transfers_and_cancel_are_isolated", test_mixed_http_jingle_transfers_and_cancel_are_isolated_sync);
        add_test("FileManager_size_limits_filter_sender_encryption_viability", test_size_limits_filter_sender_encryption_viability_sync);
        add_test("FileManager_size_limits_report_fast_sender_before_slow_sender", test_size_limits_report_fast_sender_before_slow_sender_sync);
        add_test("EntityInfo_has_feature_refreshes_unresolved_caps_hash", test_entity_info_has_feature_refreshes_unresolved_caps_hash_sync);
        add_test("FileManager_external_encryptor_preprocesses_http_send_data_before_upload", test_external_encryptor_preprocesses_http_send_data_before_upload_sync);
        add_test("FileManager_external_encryptor_rejects_non_http_send_data_before_upload", test_external_encryptor_rejects_non_http_send_data_before_upload_sync);
        add_test("FileManager_send_file_publishes_local_copy_and_marks_failed_on_transport_error", test_send_file_publishes_local_copy_and_marks_failed_on_transport_error_sync);
        add_test("FileManager_external_plaintext_source_under_data_path_is_not_decrypted", test_external_plaintext_source_under_data_path_is_not_decrypted_sync);
        add_test("FileManager_dinox_managed_storage_source_is_decoded", test_dinox_managed_storage_source_is_decoded_sync);
        add_test("Stickers_managed_child_uses_managed_source", test_sticker_managed_child_source);
        add_test("Stickers_legacy_external_path_uses_plaintext_source", test_sticker_legacy_external_source);
        add_test("Stickers_prefix_collision_uses_plaintext_source", test_sticker_prefix_collision_source);
        add_test("FileManager_send_file_unencrypted_success_publishes_complete_transfer", test_send_file_unencrypted_success_publishes_complete_transfer_sync);
        add_test("FileManager_send_file_unencrypted_cancel_after_local_store_marks_failed", test_send_file_unencrypted_cancel_after_local_store_marks_failed_sync);
        add_test("FileManager_retry_send_after_restart_uses_persisted_local_copy", test_retry_send_after_restart_uses_persisted_local_copy_sync);
        add_test("FileManager_retry_send_cancel_keeps_local_copy_failed", test_retry_send_cancel_keeps_local_copy_failed_sync);
        add_test("FileTransferWorker_runs_jobs_off_main_thread", test_transfer_worker_runs_jobs_off_main_thread_sync);
        add_test("FileTransferWorker_resumes_on_caller_context", test_transfer_worker_resumes_on_caller_context_sync);
        add_test("FileTransferWorker_propagates_worker_errors", test_transfer_worker_propagates_worker_errors_sync);
        add_test("FileTransferWorker_publish_lane_resumes_on_caller_context", test_transfer_worker_publish_lane_resumes_on_caller_context_sync);
        add_test("FileTransferWorker_publish_lane_not_blocked_by_default_lane", test_transfer_worker_publish_lane_not_blocked_by_default_lane_sync);
        add_test("FileManager_plaintext_lease_cleanup_removes_stale_tree", test_plaintext_lease_cleanup_removes_stale_tree);
        add_test("FileManager_plaintext_lease_cleanup_missing_root_is_noop", test_plaintext_lease_cleanup_missing_root_is_noop);
        add_test("FileManager_plaintext_lease_cleanup_rejects_unexpected_root", test_plaintext_lease_cleanup_rejects_unexpected_root);
        add_test("FileManager_plaintext_lease_output_file_is_adoptable", test_plaintext_lease_output_file_is_adoptable);
        add_test("PlaintextFileLeaseTarget_discard_removes_file_and_directory", test_plaintext_file_lease_target_discard_removes_file_and_directory);
        add_test("PlaintextFileLease_release_removes_file_and_directory_idempotently", test_plaintext_file_lease_release_removes_file_and_directory_idempotently);
        add_test("PlaintextFileLease_release_retries_directory_cleanup", test_plaintext_file_lease_release_retries_directory_cleanup);
        add_test("FileManager_create_plaintext_file_lease_rejects_incomplete_transfer", test_create_plaintext_file_lease_rejects_incomplete_transfer_sync);
        add_test("FileManager_plaintext_release_guard_covers_ui_purposes_and_export", test_plaintext_release_guard_covers_ui_purposes_and_export_sync);
        add_test("FileManager_verified_plaintext_input_stream_carries_meta_and_releases_lease", test_verified_plaintext_input_stream_carries_meta_and_releases_lease);
        add_test("FileManager_verified_plaintext_input_stream_close_async_releases_lease_idempotently", test_verified_plaintext_input_stream_close_async_releases_lease_idempotently);
        add_test("FileManager_verified_plaintext_input_stream_rejects_non_local_plaintext_file", test_verified_plaintext_input_stream_rejects_non_local_plaintext_file);
        add_test("FileManager_verified_plaintext_input_stream_rejects_relative_plaintext_file", test_verified_plaintext_input_stream_rejects_relative_plaintext_file);
        add_test("FileManager_verified_plaintext_input_stream_rejects_invalid_lease_directory_path", test_verified_plaintext_input_stream_rejects_invalid_lease_directory_path);
        add_test("FileManager_verified_plaintext_input_stream_rejects_file_outside_lease_directory", test_verified_plaintext_input_stream_rejects_file_outside_lease_directory);
        add_test("FileManager_verified_plaintext_input_stream_rejects_symlink_plaintext_file", test_verified_plaintext_input_stream_rejects_symlink_plaintext_file);
        add_test("FileManager_verified_plaintext_input_stream_rejects_symlink_lease_directory", test_verified_plaintext_input_stream_rejects_symlink_lease_directory);
        add_test("FileManager_verified_plaintext_input_stream_rejects_non_directory_lease_path", test_verified_plaintext_input_stream_rejects_non_directory_lease_path);
        add_test("FileManager_verified_plaintext_input_stream_rejects_non_regular_plaintext_path", test_verified_plaintext_input_stream_rejects_non_regular_plaintext_path);
        add_test("FileManager_verified_plaintext_input_stream_uses_custom_delete_func", test_verified_plaintext_input_stream_uses_custom_delete_func);
        add_test("FileManager_save_outgoing_file_stores_encrypted_copy", test_save_outgoing_file_stores_encrypted_copy_sync);
        add_test("FileManager_save_outgoing_large_stream_bounded_chunks", test_save_outgoing_large_stream_bounded_chunks_sync);
        add_test("FileManager_save_outgoing_file_cleans_pending_on_cancel", test_save_outgoing_file_cleans_pending_on_cancel_sync);
        add_test("FileManager_save_outgoing_file_keeps_existing_final_on_collision", test_save_outgoing_file_keeps_existing_final_on_collision_sync);
        add_test("FileManager_unpublished_outgoing_cleanup_removes_committed_file", test_unpublished_outgoing_cleanup_removes_committed_file);
        add_test("FileManager_export_plaintext_source_streams_to_target_pending", test_export_plaintext_source_streams_to_target_sync);
        add_test("FileManager_export_plaintext_source_keeps_target_on_decrypt_error", test_export_plaintext_source_keeps_target_on_decrypt_error_sync);
        add_test("FileManager_export_plaintext_file_rejects_incomplete_transfer", test_export_plaintext_file_rejects_incomplete_transfer_sync);
        add_test("FileManager_verify_and_commit_sets_verifying_before_publish", test_verify_and_commit_sets_verifying_before_publish_sync);
    }

    /**
     * GIO contract: A newly created stream MUST NOT be closed.
     * After close(), is_closed() MUST return true.
     * close() MUST NOT throw for a valid MemoryInputStream.
     */
    void test_stream_close() {
        var test_data = "test file content";
        var mem_stream = new MemoryInputStream.from_data(test_data.data, null);

        // Contract: stream is open initially
        assert_false(mem_stream.is_closed());

        // Contract: close must succeed
        try {
            mem_stream.close();
        } catch (Error e) {
            fail_if_reached(@"Stream close failed: $(e.message)");
        }

        // Contract: stream is closed after close()
        assert_true(mem_stream.is_closed());
    }

    void test_prefix_sniffing_stream_captures_prefix() {
        uint8[] data = "abcdef".data;
        var mem_stream = new MemoryInputStream.from_data(data, null);
        var sniffing_stream = new Dino.PrefixSniffingInputStream(mem_stream, 4);
        uint8[] buf = new uint8[2];

        try {
            ssize_t first = sniffing_stream.read(buf);
            ssize_t second = sniffing_stream.read(buf);
            ssize_t third = sniffing_stream.read(buf);

            fail_if(first != 2 || second != 2 || third != 2,
                "Sniffing stream should pass through all reads");
        } catch (Error e) {
            fail_if_reached(@"Sniffing stream read failed: $(e.message)");
        }

        uint8[] prefix = sniffing_stream.get_prefix();
        fail_if(prefix.length != 4, "Sniffed prefix must respect the configured byte limit");
        fail_if(prefix[0] != 'a' || prefix[1] != 'b' || prefix[2] != 'c' || prefix[3] != 'd',
            "Sniffed prefix must preserve byte order across reads");
    }

    void test_prefix_sniffing_stream_counts_all_passed_bytes() {
        uint8[] data = "abcdef".data;
        var mem_stream = new MemoryInputStream.from_data(data, null);
        var sniffing_stream = new Dino.PrefixSniffingInputStream(mem_stream, 2);
        uint8[] buf = new uint8[3];

        fail_if(sniffing_stream.get_passed_bytes() != 0,
            "Sniffing stream must start with a zero byte count");

        try {
            ssize_t first = sniffing_stream.read(buf);
            fail_if(first != 3 || sniffing_stream.get_passed_bytes() != 3,
                "Sniffing stream must count the first passed read");

            ssize_t second = sniffing_stream.read(buf);
            fail_if(second != 3 || sniffing_stream.get_passed_bytes() != 6,
                "Sniffing stream must count reads beyond the prefix limit");

            ssize_t eof = sniffing_stream.read(buf);
            fail_if(eof != 0 || sniffing_stream.get_passed_bytes() != 6,
                "Sniffing stream must not count EOF as passed bytes");
        } catch (Error e) {
            fail_if_reached(@"Sniffing stream read failed: $(e.message)");
        }

        uint8[] prefix = sniffing_stream.get_prefix();
        fail_if(prefix.length != 2, "Sniffed prefix must still respect the configured byte limit");
        fail_if(prefix[0] != 'a' || prefix[1] != 'b',
            "Counting all bytes must not change prefix capture");
    }

    void test_prefix_sniffing_stream_returns_copy() {
        uint8[] data = "abc".data;
        var mem_stream = new MemoryInputStream.from_data(data, null);
        var sniffing_stream = new Dino.PrefixSniffingInputStream(mem_stream, 3);
        uint8[] buf = new uint8[3];

        try {
            sniffing_stream.read(buf);
        } catch (Error e) {
            fail_if_reached(@"Sniffing stream read failed: $(e.message)");
        }

        uint8[] first = sniffing_stream.get_prefix();
        first[0] = 'z';
        uint8[] second = sniffing_stream.get_prefix();
        fail_if(second[0] != 'a', "get_prefix() must not expose mutable internal storage");
    }

    void test_hashes_match_standard_base64() {
        assert_true(Dino.FileManager.hashes_match("SGVsbG8=", "SGVsbG8="));
    }

    void test_hashes_match_url_safe_base64() {
        assert_true(Dino.FileManager.hashes_match("ab-c_d==", "ab+c/d=="));
    }

    void test_hashes_match_unpadded_expected() {
        assert_true(Dino.FileManager.hashes_match("SGVsbG8", "SGVsbG8="));
    }

    void test_hashes_match_rejects_mismatch() {
        assert_false(Dino.FileManager.hashes_match("SGVsbG8=", "V29ybGQ="));
    }

    void test_compute_file_hashes_preserves_xep_base64_sync() {
        var loop = new MainLoop();
        test_compute_file_hashes_preserves_xep_base64.begin((obj, res) => {
            test_compute_file_hashes_preserves_xep_base64.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_compute_file_hashes_preserves_xep_base64() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string file_path = Path.build_filename(temp_dir, "metadata.txt");
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            FileUtils.set_contents(file_path, "send metadata hashes\n");

            var checksum_types = new ArrayList<ChecksumType>();
            checksum_types.add(ChecksumType.SHA256);
            checksum_types.add(ChecksumType.SHA512);

            var hashes = yield Dino.compute_file_hashes(File.new_for_path(file_path), checksum_types);
            fail_if_not_eq_str(hashes[ChecksumType.SHA256], "FY1VD/jg1uDdyF08bVQOpXOGZd1BtSWEoxsHEV3O+gU=",
                "SHA-256 metadata hash must keep XEP-0300 Base64 encoding");
            fail_if_not_eq_str(hashes[ChecksumType.SHA512], "8Ld0qsNogC5y5JZLJVMsDlTwEU0qkU178PKceThZPpdcD5yWIyxQ1JgwRVhiyp8b2TORCdPEeY6zK3F29LH1cQ==",
                "SHA-512 metadata hash must keep XEP-0300 Base64 encoding");
        } catch (Error e) {
            fail_if_reached(@"Metadata hash test failed: $(e.message)");
        } finally {
            try { File.new_for_path(file_path).delete(null); } catch (Error e) {}
            DirUtils.remove(temp_dir);
        }
    }

    void test_compute_file_hashes_sync_cancelled_returns_no_hashes() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string file_path = Path.build_filename(temp_dir, "metadata.txt");
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            FileUtils.set_contents(file_path, "send metadata hashes\n");

            var checksum_types = new ArrayList<ChecksumType>();
            checksum_types.add(ChecksumType.SHA256);
            checksum_types.add(ChecksumType.SHA512);
            var cancellable = new Cancellable();
            cancellable.cancel();

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING, "*Failed to read file for checksum:*");
            var hashes = Dino.compute_file_hashes_sync(File.new_for_path(file_path), checksum_types, cancellable);
            GLib.Test.assert_expected_messages();
            fail_if(hashes.has_key(ChecksumType.SHA256),
                "cancelled metadata hashing must not publish a partial SHA-256 value");
            fail_if(hashes.has_key(ChecksumType.SHA512),
                "cancelled metadata hashing must not publish a partial SHA-512 value");
        } catch (Error e) {
            fail_if_reached(@"Cancelled metadata hash test failed: $(e.message)");
        } finally {
            try { File.new_for_path(file_path).delete(null); } catch (Error e) {}
            DirUtils.remove(temp_dir);
        }
    }

    void test_generic_metadata_omits_hashes_on_hash_read_error_sync() {
        var loop = new MainLoop();
        test_generic_metadata_omits_hashes_on_hash_read_error.begin((obj, res) => {
            test_generic_metadata_omits_hashes_on_hash_read_error.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_generic_metadata_omits_hashes_on_hash_read_error() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        DirUtils.create_with_parents(temp_dir, 0700);

        var provider = new Dino.GenericFileMetadataProvider();
        var metadata = new Xmpp.Xep.FileMetadataElement.FileMetadata();

        try {
            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING, "*Failed to read file for checksum:*");
            yield provider.fill_metadata(File.new_for_path(temp_dir), metadata);
            GLib.Test.assert_expected_messages();

            fail_if(!metadata.hashes.is_empty,
                "metadata provider must omit XEP-0300 hashes when hashing did not produce complete values");
        } finally {
            DirUtils.remove(temp_dir);
        }
    }

    void test_image_metadata_decodes_off_main_thread_sync() {
        var loop = new MainLoop();
        test_image_metadata_decodes_off_main_thread.begin((obj, res) => {
            test_image_metadata_decodes_off_main_thread.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_image_metadata_decodes_off_main_thread() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-image-metadata-" + Uuid.string_random());
        string image_path = Path.build_filename(temp_dir, "image.png");
        ulong hook_id = 0;
        uint signal_id = 0;
        int observed_decode = 0;
        int decoded_on_main = 0;
        int64 main_thread_id = (int64) Thread.self<void*>();
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var image = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, 640, 320);
            image.fill(0x448866ff);
            image.save(image_path, "png");

            // Observe the real decoder used by the public provider, rather
            // than asserting only that the file-open operation yields.
            var loader = new Gdk.PixbufLoader();
            try { loader.close(); } catch (Error ignored) { }
            signal_id = GLib.Signal.lookup("size-prepared", typeof(Gdk.PixbufLoader));
            hook_id = GLib.Signal.add_emission_hook(signal_id, 0, (hint, values) => {
                AtomicInt.set(ref observed_decode, 1);
                if ((int64) Thread.self<void*>() == main_thread_id) {
                    AtomicInt.set(ref decoded_on_main, 1);
                }
                return true;
            });
            var provider = new Dino.ImageFileMetadataProvider();
            var metadata = new Xmpp.Xep.FileMetadataElement.FileMetadata();
            yield provider.fill_metadata(File.new_for_path(image_path), metadata);
            fail_if(AtomicInt.get(ref observed_decode) == 0, "fixture must observe the actual image decoder");
            fail_if(AtomicInt.get(ref decoded_on_main) != 0,
                "image metadata decoding must not block the caller's main thread");
            fail_if((int64) Thread.self<void*>() != main_thread_id,
                "metadata completion must return to the caller's thread");
            fail_if(metadata.width != 640 || metadata.height != 320,
                "metadata must keep the original image dimensions");
            fail_if(metadata.thumbnails.size != 1 || metadata.thumbnails[0].width != 4 || metadata.thumbnails[0].height != 2,
                "metadata must preserve the existing tiny thumbnail format");
        } catch (Error e) {
            fail_if_reached(e.message);
        } finally {
            if (hook_id != 0) GLib.Signal.remove_emission_hook(signal_id, hook_id);
            FileUtils.unlink(image_path);
            DirUtils.remove(temp_dir);
        }
    }

    void test_image_metadata_rejects_unsafe_optional_previews_sync() {
        var loop = new MainLoop();
        test_image_metadata_rejects_unsafe_optional_previews.begin((obj, res) => {
            test_image_metadata_rejects_unsafe_optional_previews.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_image_metadata_rejects_unsafe_optional_previews() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-image-metadata-bounds-" + Uuid.string_random());
        string image_path = Path.build_filename(temp_dir, "image.png");
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var provider = new Dino.ImageFileMetadataProvider();
            for (int variant = 0; variant < 3; variant++) {
                uint8[] fixture;
                if (variant == 0) {
                    // Malformed PNG with a 10000x10000 IHDR: even oversized
                    // headers must not leave partial metadata after a decode error.
                    fixture = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAJxAAACcQCAIAAAA1LPVwAAAAAElEQVQ1rwYeAAAAAElFTkSuQmCC");
                } else if (variant == 1) {
                    fixture = "not an image".data;
                } else {
                    fixture = "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'/>".data;
                }
                FileUtils.set_data(image_path, fixture);
                var metadata = new Xmpp.Xep.FileMetadataElement.FileMetadata();
                metadata.name = "original.png";
                metadata.size = fixture.length;
                yield provider.fill_metadata(File.new_for_path(image_path), metadata);
                fail_if(metadata.width != -1 || metadata.height != -1 || !metadata.thumbnails.is_empty,
                    "rejected optional previews must not publish partial image metadata");
                uint8[] after;
                FileUtils.get_data(image_path, out after);
                fail_if(metadata.name != "original.png" || metadata.size != fixture.length ||
                    new Bytes(after).compare(new Bytes(fixture)) != 0,
                    "preview rejection must preserve the original file and upload metadata");
            }
            // A file above the preview budget can still be uploaded. Extend a
            // small real PNG instead of allocating a large in-memory fixture.
            var image = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, 64, 32);
            image.fill(0x448866ff);
            image.save(image_path, "png");
            FileIOStream output = File.new_for_path(image_path).open_readwrite();
            ((Seekable) output).truncate(25 * 1024 * 1024 + 1);
            output.close();
            var large_metadata = new Xmpp.Xep.FileMetadataElement.FileMetadata();
            large_metadata.size = 25 * 1024 * 1024 + 1;
            yield provider.fill_metadata(File.new_for_path(image_path), large_metadata);
            fail_if(!large_metadata.thumbnails.is_empty || large_metadata.width != -1 ||
                File.new_for_path(image_path).query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE).get_size() != large_metadata.size,
                "preview byte limits must leave the upload file intact");

            image.save(image_path, "png");
            var valid_metadata = new Xmpp.Xep.FileMetadataElement.FileMetadata();
            yield provider.fill_metadata(File.new_for_path(image_path), valid_metadata);
            fail_if(valid_metadata.width != 64 || valid_metadata.height != 32 || valid_metadata.thumbnails.size != 1,
                "valid images must still work after rejected preview jobs");
        } catch (Error e) {
            fail_if_reached(e.message);
        } finally {
            FileUtils.unlink(image_path);
            DirUtils.remove(temp_dir);
        }
    }

    void test_message_storage_chat_server_id_lookup_handles_resourceful_sender() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-message-storage-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Dino.Database? db = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "message-storage-server-id-test");

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var bob_bare = new Xmpp.Jid("bob@example.test");
            var conversation = new Dino.Entities.Conversation(bob_bare, account, Dino.Entities.Conversation.Type.CHAT);

            var message = new Dino.Entities.Message("file announcement shell");
            message.account = account;
            message.counterpart = bob_bare.with_resource("laptop");
            message.ourpart = account.full_jid;
            message.direction = Dino.Entities.Message.DIRECTION_RECEIVED;
            message.type_ = Dino.Entities.Message.Type.CHAT;
            message.time = new DateTime.now_utc();
            message.local_time = new DateTime.now_utc();
            message.marked = Dino.Entities.Message.Marked.RECEIVED;
            message.stanza_id = "origin-id-1";
            message.server_id = "mam-server-id-1";
            message.persist((!) db);

            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.MessageStorage.start(stream_interactor, (!) db);
            Dino.MessageStorage? storage = stream_interactor.get_module<Dino.MessageStorage>(Dino.MessageStorage.IDENTITY);
            fail_if(storage == null, "test setup must start MessageStorage");

            Dino.Entities.Message? found_by_reference = ((!) storage).get_message_by_referencing_id("mam-server-id-1", conversation);
            fail_if(found_by_reference == null,
                "bare 1:1 conversation lookup must find a MAM server-id row stored with sender resource");
            Dino.Entities.Message referenced_message = (!) found_by_reference;
            fail_if(referenced_message.id != message.id,
                "MAM server-id lookup must return the resourceful stored message");

            Dino.Entities.Message? found_by_server_id = ((!) storage).get_message_by_server_id("mam-server-id-1", conversation);
            fail_if(found_by_server_id == null,
                "direct server-id lookup must also ignore sender resource for bare 1:1 conversations");
            Dino.Entities.Message server_id_message = (!) found_by_server_id;
            fail_if(server_id_message.id != message.id,
                "direct server-id lookup must return the resourceful stored message");
        } catch (Error e) {
            fail_if_reached(@"MessageStorage server-id lookup test failed: $(e.message)");
        } finally {
            if (db != null) {
                ((!) db).close();
            }
            FileUtils.remove(db_path);
            DirUtils.remove(temp_dir);
        }
    }

    void test_incoming_shell_applies_mime_for_decryptor_classification() {
        var meta = new Dino.FileMeta();
        meta.file_name = "payload";
        meta.mime_type = "application/pgp-encrypted";
        meta.size = 4096;
        meta.message_db_id = 73;

        var file_transfer = new Dino.Entities.FileTransfer();
        Dino.FileManager.apply_incoming_file_meta_to_transfer_for_tests(file_transfer, meta);

        try {
            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            var decryptor = new TestMimeOnlyFileDecryptor();

            fail_if_not_eq_str(file_transfer.file_name, "payload",
                "incoming transfer shell must keep provider filename metadata");
            fail_if_not_eq_str(file_transfer.mime_type, "application/pgp-encrypted",
                "incoming transfer shell must expose provider MIME metadata before decryptor classification");
            fail_if(file_transfer.size != 4096,
                "incoming transfer shell must keep known provider size metadata");
            fail_if(file_transfer.message_db_id != 73,
                "incoming transfer shell must keep the announcing message relation independently from transport info");
            fail_if(!decryptor.can_decrypt_file(conversation, file_transfer, new Dino.FileReceiveData()),
                "MIME-only encrypted payloads must remain visible to receive decryptor classification");
        } catch (Error e) {
            fail_if_reached(@"Incoming shell MIME classification test failed: $(e.message)");
        }
    }

    void test_registered_decryptor_selected_from_provider_mime_on_incoming_classification() {
        try {
            var manager = Dino.FileManager.create_for_tests();
            var decryptor = new TestMimeOnlyFileDecryptor();
            manager.add_file_decryptor(decryptor);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            var provider = new TestPlainIncomingProvider(123);
            var meta = new Dino.FileMeta();
            meta.file_name = "payload";
            meta.mime_type = "application/pgp-encrypted";
            meta.size = 4096;
            var time = new DateTime.now_utc();

            Dino.Entities.FileTransfer file_transfer = manager.create_file_transfer_from_provider_incoming(
                    provider, "incoming-id", new Xmpp.Jid("bob@example.test/resource"), time, time,
                    conversation, new Dino.FileReceiveData(), meta);

            fail_if(decryptor.can_decrypt_calls == 0,
                "registered decryptor must be asked during incoming classification");
            fail_if_not_eq_str(decryptor.last_seen_mime_type, "application/pgp-encrypted",
                "registered decryptor must see provider MIME metadata from the transfer shell");
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.PGP,
                "registered MIME-only decryptor must classify the incoming transfer as PGP");
            fail_if(file_transfer.provider != provider.get_id(),
                "incoming transfer must keep the selected provider id");
            fail_if_not_eq_str(file_transfer.file_name, "payload",
                "incoming classification must keep provider filename metadata");
            fail_if_not_eq_str(file_transfer.mime_type, "application/pgp-encrypted",
                "incoming classification must keep provider MIME metadata");
            fail_if(file_transfer.size != 4096,
                "incoming classification must keep provider size metadata");
        } catch (Error e) {
            fail_if_reached(@"Registered decryptor MIME classification test failed: $(e.message)");
        }
    }

    void test_download_source_uses_provider_liveness() {
        var manager = Dino.FileManager.create_for_tests();
        var provider = new TestPlainIncomingProvider(Dino.FileManager.JINGLE_PROVIDER_ID);
        manager.add_provider(provider);

        var received = new Dino.Entities.FileTransfer();
        received.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
        received.provider = Dino.FileManager.JINGLE_PROVIDER_ID;
        received.state = Dino.Entities.FileTransfer.State.NOT_STARTED;
        received.info = "live-direct-offer";

        fail_if(manager.has_usable_download_source(received),
            "A direct receive transfer loaded without a live runtime offer must not be downloadable");

        received.set_transient_download_source_available(true);
        fail_if(!manager.has_usable_download_source(received),
            "A not-started direct receive transfer must be downloadable while its provider source is live");

        provider.source_available = false;
        fail_if(manager.has_usable_download_source(received),
            "A direct receive transfer must not be downloadable after its live provider source disappears");

        provider.source_available = true;
        received.state = Dino.Entities.FileTransfer.State.FAILED;
        fail_if(manager.has_usable_download_source(received),
            "A failed direct receive transfer must not be offered as reloadable even if a stale provider entry remains");

        var sent = new Dino.Entities.FileTransfer();
        sent.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        sent.provider = Dino.FileManager.JINGLE_PROVIDER_ID;
        sent.state = Dino.Entities.FileTransfer.State.FAILED;
        provider.source_available = false;
        fail_if(!manager.has_usable_download_source(sent),
            "Sent transfers keep their retry decision separate from receive download source liveness");
    }

    void test_late_provider_mime_classifies_registered_decryptor_sync() {
        var loop = new MainLoop();
        test_late_provider_mime_classifies_registered_decryptor.begin((obj, res) => {
            test_late_provider_mime_classifies_registered_decryptor.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_late_provider_mime_classifies_registered_decryptor() {
        try {
            var manager = Dino.FileManager.create_for_tests();
            var decryptor = new TestMimeOnlyFileDecryptor();
            manager.add_file_decryptor(decryptor);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            var provider = new TestLateMimeMetadataProvider(124);
            var initial_meta = new Dino.FileMeta();
            initial_meta.file_name = "payload";
            initial_meta.size = -1;
            var time = new DateTime.now_utc();
            var receive_data = new Dino.FileReceiveData();

            Dino.Entities.FileTransfer file_transfer = manager.create_file_transfer_from_provider_incoming(
                    provider, "incoming-id", new Xmpp.Jid("bob@example.test/resource"), time, time,
                    conversation, receive_data, initial_meta);

            fail_if(file_transfer.encryption != Dino.Entities.Encryption.NONE,
                "incoming transfer with unknown initial MIME must start unclassified");
            fail_if(file_transfer.mime_type != null,
                "incoming transfer with unknown initial MIME must not invent MIME metadata");
            fail_if(file_transfer.size != -1,
                "incoming transfer with unknown initial metadata must keep unknown size");

            bool selected = yield manager.prepare_receive_pipeline_has_decryptor_for_tests(
                    provider, file_transfer, conversation, receive_data);

            fail_if(!provider.metadata_called,
                "late provider metadata path must be exercised");
            fail_if(!selected,
                "late provider MIME metadata must select the registered decryptor");
            fail_if_not_eq_str(decryptor.last_seen_mime_type, "application/pgp-encrypted",
                "registered decryptor must see late provider MIME metadata");
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.PGP,
                "late provider MIME metadata must classify the transfer as PGP");
            fail_if_not_eq_str(file_transfer.mime_type, "application/pgp-encrypted",
                "late provider MIME metadata must be published to the transfer");
            fail_if(file_transfer.size != 4096,
                "late provider size metadata must be published to the transfer");
            fail_if(file_transfer.path != null,
                "late metadata classification must not publish a storage path");
            fail_if(file_transfer.is_plaintext_release_allowed(),
                "late metadata classification must not allow plaintext release");
        } catch (Error e) {
            fail_if_reached(@"Late provider MIME classification test failed: $(e.message)");
        }
    }

    void test_late_provider_classification_preserves_existing_encryption_sync() {
        var loop = new MainLoop();
        test_late_provider_classification_preserves_existing_encryption.begin((obj, res) => {
            test_late_provider_classification_preserves_existing_encryption.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_late_provider_classification_preserves_existing_encryption() {
        try {
            var manager = Dino.FileManager.create_for_tests();
            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            var provider = new TestLateProviderEncryptionMetadataProvider(125);
            var initial_meta = new Dino.FileMeta();
            initial_meta.file_name = "payload";
            initial_meta.size = -1;
            var time = new DateTime.now_utc();
            var receive_data = new Dino.FileReceiveData();

            Dino.Entities.FileTransfer file_transfer = manager.create_file_transfer_from_provider_incoming(
                    provider, "incoming-id", new Xmpp.Jid("bob@example.test/resource"), time, time,
                    conversation, receive_data, initial_meta);
            file_transfer.encryption = Dino.Entities.Encryption.OMEMO;
            file_transfer.encryption_protocol = null;

            yield manager.prepare_receive_pipeline_has_decryptor_for_tests(
                    provider, file_transfer, conversation, receive_data);

            fail_if(!provider.metadata_called,
                "late provider metadata path must be exercised");
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.OMEMO,
                "late provider classification must not overwrite existing transfer encryption");
            fail_if(file_transfer.encryption_protocol != null,
                "late provider classification must not add a protocol to an already classified transfer");
            fail_if_not_eq_str(file_transfer.mime_type, "application/pgp-encrypted",
                "late provider metadata may still update transport MIME metadata");
            fail_if(file_transfer.size != 4096,
                "late provider metadata may still update transport size metadata");
        } catch (Error e) {
            fail_if_reached(@"Late provider classification preservation test failed: $(e.message)");
        }
    }

    void test_unconstrained_file_encryptor_accepts_any_sender() {
        Dino.FileEncryptor encryptor = new TestFileEncryptor();
        fail_if(!Dino.FileManager.file_encryptor_accepts_sender(encryptor, Dino.FileManager.HTTP_PROVIDER_ID),
            "File encryptors without a sender requirement must be allowed to use HTTP Upload");
        fail_if(!Dino.FileManager.file_encryptor_accepts_sender(encryptor, 1),
            "File encryptors without a sender requirement must be allowed to use Jingle");
    }

    void test_file_encryptor_sender_requirement_blocks_jingle() {
        Dino.FileEncryptor encryptor = new TestRequiredSenderFileEncryptor(Dino.FileManager.HTTP_PROVIDER_ID);
        fail_if(!Dino.FileManager.file_encryptor_accepts_sender(encryptor, Dino.FileManager.HTTP_PROVIDER_ID),
            "HTTP-bound file encryptors must accept the HTTP Upload sender");
        fail_if(Dino.FileManager.file_encryptor_accepts_sender(encryptor, 1),
            "HTTP-bound file encryptors must not be paired with the Jingle sender");
    }

    void test_file_encryptor_rejection_reason_fails_before_slot_sync() {
        var loop = new MainLoop();
        test_file_encryptor_rejection_reason_fails_before_slot.begin((obj, res) => {
            test_file_encryptor_rejection_reason_fails_before_slot.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_file_encryptor_rejection_reason_fails_before_slot() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string input_path = Path.build_filename(temp_dir, "payload-reject.txt");
        Dino.Database? db = null;
        string? stored_path = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            FileUtils.set_contents(input_path, "outgoing file-encryptor rejection reason\n");

            db = new Dino.Database(db_path, "send-encryptor-rejection-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);

            var file_encryption = new Dino.Security.FileEncryption("send-encryptor-rejection-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var sender = new TestRecordingFileSender();
            var encryptor = new TestRejectingFileEncryptor(Dino.Entities.Encryption.PGP,
                "synthetic file-encryptor readiness rejection");
            ((!) manager).add_sender(sender);
            ((!) manager).add_file_encryptor(encryptor);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.PGP;

            Dino.Entities.FileTransfer? published_transfer = null;
            bool transport_started_before_publish = false;
            Gee.ArrayList<Dino.Entities.FileTransfer.Phase> phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                transport_started_before_publish = sender.prepare_called || sender.send_called;
                fail_if(file_transfer.id == -1, "received_file must publish a persisted outgoing transfer");
                fail_if(file_transfer.path == null, "received_file must publish the saved local outgoing path");
                stored_path = file_transfer.path;
            });

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*send_file: file encryption rejected: synthetic file-encryptor readiness rejection*");
            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*Send file error: synthetic file-encryptor readiness rejection*");
            yield ((!) manager).send_file(File.new_for_path(input_path), conversation, (file_transfer) => {
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            });
            GLib.Test.assert_expected_messages();

            fail_if(published_transfer == null,
                "file-encryptor rejection must publish the local outgoing copy before failing");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(transport_started_before_publish,
                "local publication must happen before slot preparation starts");

            fail_if(!encryptor.can_encrypt_called,
                "FileManager must ask the encryptor whether it can claim the transfer");
            fail_if(!encryptor.rejection_reason_called,
                "FileManager must query the rejection reason after no encryptor claims an otherwise sendable transfer");
            fail_if(encryptor.encrypt_called,
                "rejected file encryptor must not run encryption");
            fail_if(sender.prepare_called,
                "file-encryptor rejection must fail before sender slot preparation");
            fail_if(sender.send_called,
                "file-encryptor rejection must fail before upload");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "file-encryptor rejection must end in FAILED phase");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "file-encryptor rejection must persist FAILED state in memory");
            fail_if(file_transfer.phase_error == null ||
                    !((!) file_transfer.phase_error).contains("synthetic file-encryptor readiness rejection"),
                "file-encryptor rejection must keep the specific reason on the transfer");
            fail_if(!file_transfer.input_stream.is_closed(),
                "file-encryptor rejection must close the upload input stream");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.ENCRYPTING) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.UPLOADING) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "file-encryptor rejection must fail before encrypt, slot, upload or complete phases");
            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "file-encryptor rejection must persist the transfer as failed in the database");
        } catch (Error e) {
            fail_if_reached(@"File encryptor rejection reason test failed: $(e.message)");
        } finally {
            if (db != null) ((!) db).close();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_file_encryptor_rejection_reason_does_not_mask_no_sender_sync() {
        var loop = new MainLoop();
        test_file_encryptor_rejection_reason_does_not_mask_no_sender.begin((obj, res) => {
            test_file_encryptor_rejection_reason_does_not_mask_no_sender.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_file_encryptor_rejection_reason_does_not_mask_no_sender() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string input_path = Path.build_filename(temp_dir, "payload-no-sender.txt");
        Dino.Database? db = null;
        string? stored_path = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            FileUtils.set_contents(input_path, "outgoing no-sender selection failure\n");

            db = new Dino.Database(db_path, "send-no-sender-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);

            var file_encryption = new Dino.Security.FileEncryption("send-no-sender-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var sender = new TestUnavailableFileSender();
            var encryptor = new TestRejectingFileEncryptor(Dino.Entities.Encryption.PGP,
                "must not mask no-sender");
            ((!) manager).add_sender(sender);
            ((!) manager).add_file_encryptor(encryptor);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.PGP;

            Dino.Entities.FileTransfer? published_transfer = null;
            bool transport_started_before_publish = false;
            Gee.ArrayList<Dino.Entities.FileTransfer.Phase> phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                transport_started_before_publish = sender.prepare_called || sender.send_called;
                fail_if(file_transfer.id == -1, "received_file must publish a persisted outgoing transfer");
                fail_if(file_transfer.path == null, "received_file must publish the saved local outgoing path");
                stored_path = file_transfer.path;
            });

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*send_file: no sender/encryptor available*");
            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*Send file error: No sender/encryptor combination available*");
            yield ((!) manager).send_file(File.new_for_path(input_path), conversation, (file_transfer) => {
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            });
            GLib.Test.assert_expected_messages();

            fail_if(published_transfer == null,
                "no-sender failure must publish the local outgoing copy before failing");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(transport_started_before_publish,
                "local publication must happen before slot preparation starts");

            fail_if(!sender.can_send_called,
                "FileManager must check sender availability before encryptor rejection reasons");
            fail_if(sender.prepare_called,
                "unavailable sender must not prepare slot data");
            fail_if(sender.send_called,
                "unavailable sender must not upload");
            fail_if(encryptor.can_encrypt_called || encryptor.rejection_reason_called || encryptor.encrypt_called,
                "FileManager must not query encryptor rejection reasons when no sender can send");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "no-sender selection failure must end in FAILED phase");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "no-sender selection failure must persist FAILED state in memory");
            fail_if(file_transfer.phase_error == null ||
                    !((!) file_transfer.phase_error).contains("No sender/encryptor combination available") ||
                    ((!) file_transfer.phase_error).contains("must not mask no-sender"),
                "no-sender path must keep the generic selection failure");
            fail_if(!file_transfer.input_stream.is_closed(),
                "no-sender selection failure must close the upload input stream");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.ENCRYPTING) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.UPLOADING) ||
                    phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "no-sender selection failure must fail before encrypt, slot, upload or complete phases");
            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "no-sender selection failure must persist the transfer as failed in the database");
        } catch (Error e) {
            fail_if_reached(@"No-sender selection failure test failed: $(e.message)");
        } finally {
            if (db != null) ((!) db).close();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_external_file_encryptor_meta_fails_closed() {
        var file_transfer = new Dino.Entities.FileTransfer();
        file_transfer.file_name = "payload.bin";
        file_transfer.encryption = Dino.Entities.Encryption.PGP;

        var unmarked_meta = new Dino.FileMeta();
        try {
            Dino.FileManager.validate_external_file_encryptor_meta(file_transfer, unmarked_meta);
            fail_if_reached("Encrypted external file encryptor output must be marked as already encrypted");
        } catch (Dino.FileSendError.ENCRYPTION_FAILED e) {
            assert_true(true);
        } catch (Error e) {
            fail_if_reached(@"Unexpected validation error: $(e.message)");
        }

        var marked_meta = new Dino.FileMeta();
        marked_meta.upload_payload_is_encrypted = true;
        try {
            Dino.FileManager.validate_external_file_encryptor_meta(file_transfer, marked_meta);
        } catch (Error e) {
            fail_if_reached(@"Marked encrypted payload metadata must be accepted: $(e.message)");
        }

        file_transfer.encryption = Dino.Entities.Encryption.NONE;
        try {
            Dino.FileManager.validate_external_file_encryptor_meta(file_transfer, unmarked_meta);
        } catch (Error e) {
            fail_if_reached(@"Unencrypted transfers must not require encrypted-payload metadata: $(e.message)");
        }
    }

    void test_external_encryptor_runs_before_slot_prepare_sync() {
        var loop = new MainLoop();
        test_external_encryptor_runs_before_slot_prepare.begin((obj, res) => {
            test_external_encryptor_runs_before_slot_prepare.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_external_encryptor_runs_before_slot_prepare() {
        try {
            var manager = Dino.FileManager.create_for_tests();
            var sender = new TestRecordingFileSender();
            var encryptor = new TestRecordingFileEncryptor(4352, true);
            manager.add_sender(sender);
            manager.add_file_encryptor(encryptor);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            var file_transfer = create_send_file_transfer(account, Dino.Entities.Encryption.PGP, 4096);
            Gee.ArrayList<Dino.Entities.FileTransfer.Phase> phases = collect_phases(file_transfer);

            yield manager.send_file_transport_pipeline_for_tests(conversation, file_transfer);

            fail_if(!encryptor.encrypt_called,
                "external encryptor must run before slot preparation");
            fail_if(!sender.prepare_called,
                "sender slot preparation must run after external encryption");
            fail_if(sender.prepare_meta_size != 4352,
                "sender must see final encrypted payload size, not plaintext size");
            fail_if(!sender.prepare_meta_upload_payload_is_encrypted,
                "sender must see external encrypted-payload marker");
            fail_if(!sender.send_called,
                "sender upload path must run after encrypted metadata is prepared");
            fail_if(sender.send_meta_size != 4352,
                "sender upload must receive final encrypted payload size, not plaintext size");
            fail_if(!sender.send_meta_upload_payload_is_encrypted,
                "sender upload must receive external encrypted-payload marker");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "external encryption phase must precede slot preparation");
        } catch (Error e) {
            fail_if_reached(@"External encryptor orchestration test failed: $(e.message)");
        }
    }

    void test_unmarked_external_encryptor_meta_never_requests_slot_sync() {
        var loop = new MainLoop();
        test_unmarked_external_encryptor_meta_never_requests_slot.begin((obj, res) => {
            test_unmarked_external_encryptor_meta_never_requests_slot.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_unmarked_external_encryptor_meta_never_requests_slot() {
        try {
            var manager = Dino.FileManager.create_for_tests();
            var sender = new TestRecordingFileSender();
            var encryptor = new TestRecordingFileEncryptor(4352, false);
            manager.add_sender(sender);
            manager.add_file_encryptor(encryptor);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            var file_transfer = create_send_file_transfer(account, Dino.Entities.Encryption.PGP, 4096);
            Gee.ArrayList<Dino.Entities.FileTransfer.Phase> phases = collect_phases(file_transfer);

            try {
                yield manager.send_file_transport_pipeline_for_tests(conversation, file_transfer);
                fail_if_reached("unmarked external encrypted output must fail before slot preparation");
            } catch (Dino.FileSendError.ENCRYPTION_FAILED e) {
                assert_true(true);
            }

            fail_if(!encryptor.encrypt_called,
                "unmarked external encryptor path must exercise encryption before failing");
            fail_if(sender.prepare_called,
                "sender must not request a slot after unmarked external encrypted output");
            fail_if(sender.send_called,
                "sender must not upload after unmarked external encrypted output");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT),
                "unmarked external encrypted output must fail before REQUESTING_SLOT phase");
        } catch (Error e) {
            fail_if_reached(@"Unmarked external encryptor orchestration test failed: $(e.message)");
        }
    }

    void test_direct_sender_uses_original_meta_without_external_encryptor_sync() {
        var loop = new MainLoop();
        test_direct_sender_uses_original_meta_without_external_encryptor.begin((obj, res) => {
            test_direct_sender_uses_original_meta_without_external_encryptor.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_direct_sender_uses_original_meta_without_external_encryptor() {
        try {
            var manager = Dino.FileManager.create_for_tests();
            var sender = new TestRecordingFileSender(true);
            var encryptor = new TestRecordingFileEncryptor(4352, true);
            manager.add_sender(sender);
            manager.add_file_encryptor(encryptor);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            var file_transfer = create_send_file_transfer(account, Dino.Entities.Encryption.OMEMO, 4096);
            Gee.ArrayList<Dino.Entities.FileTransfer.Phase> phases = collect_phases(file_transfer);

            yield manager.send_file_transport_pipeline_for_tests(conversation, file_transfer);

            fail_if(encryptor.encrypt_called,
                "direct sender encryption must not run the external file encryptor");
            fail_if(!sender.prepare_called,
                "direct sender path must still prepare send data");
            fail_if(sender.prepare_meta_size != 4096,
                "direct sender encryption path must prepare with original plaintext metadata");
            fail_if(sender.prepare_meta_upload_payload_is_encrypted,
                "direct sender encryption path must not mark upload payload pre-encrypted");
            fail_if(!sender.send_called,
                "direct sender path must still run upload through the selected sender");
            fail_if(sender.send_meta_size != 4096,
                "direct sender upload path must receive original plaintext metadata");
            fail_if(sender.send_meta_upload_payload_is_encrypted,
                "direct sender upload path must not mark upload payload pre-encrypted");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.ENCRYPTING),
                "direct sender encryption path must not expose an external ENCRYPTING phase");
        } catch (Error e) {
            fail_if_reached(@"Direct sender orchestration test failed: $(e.message)");
        }
    }

    void test_auto_sender_keeps_default_priority_sync() {
        var loop = new MainLoop();
        test_auto_sender_keeps_default_priority.begin((obj, res) => {
            test_auto_sender_keeps_default_priority.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_auto_sender_keeps_default_priority() {
        try {
            var manager = Dino.FileManager.create_for_tests();
            var http_sender = new TestRecordingFileSender(false, false, false, Dino.FileManager.HTTP_PROVIDER_ID, 100);
            var jingle_sender = new TestRecordingFileSender(false, false, false, Dino.FileManager.JINGLE_PROVIDER_ID, 50);
            manager.add_sender(http_sender);
            manager.add_sender(jingle_sender);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            var file_transfer = create_send_file_transfer(account, Dino.Entities.Encryption.NONE, 4096);

            yield manager.send_file_transport_pipeline_for_tests(conversation, file_transfer);

            fail_if(!http_sender.prepare_called || !http_sender.send_called,
                "automatic sender selection must keep the higher-priority HTTP sender");
            fail_if(jingle_sender.prepare_called || jingle_sender.send_called,
                "automatic sender selection must not use lower-priority Jingle when HTTP can send");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "automatic sender transfer must complete through the normal send pipeline");
        } catch (Error e) {
            fail_if_reached(@"Automatic sender priority test failed: $(e.message)");
        }
    }

    void test_preferred_sender_overrides_default_priority_sync() {
        var loop = new MainLoop();
        test_preferred_sender_overrides_default_priority.begin((obj, res) => {
            test_preferred_sender_overrides_default_priority.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_preferred_sender_overrides_default_priority() {
        try {
            var manager = Dino.FileManager.create_for_tests();
            var http_sender = new TestRecordingFileSender(false, false, false, Dino.FileManager.HTTP_PROVIDER_ID, 100);
            var jingle_sender = new TestRecordingFileSender(false, false, false, Dino.FileManager.JINGLE_PROVIDER_ID, 50);
            manager.add_sender(http_sender);
            manager.add_sender(jingle_sender);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            var file_transfer = create_send_file_transfer(account, Dino.Entities.Encryption.NONE, 4096);
            file_transfer.preferred_file_sender_id = Dino.FileManager.JINGLE_PROVIDER_ID;

            yield manager.send_file_transport_pipeline_for_tests(conversation, file_transfer);

            fail_if(http_sender.prepare_called || http_sender.send_called,
                "explicit Jingle sender preference must skip the higher-priority HTTP sender");
            fail_if(!jingle_sender.prepare_called || !jingle_sender.send_called,
                "explicit Jingle sender preference must use the requested lower-priority sender");
            fail_if(file_transfer.provider != Dino.FileManager.JINGLE_PROVIDER_ID,
                "outgoing transfer must persist the explicitly selected Jingle sender provider id");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "preferred sender transfer must still complete through the normal send pipeline");
        } catch (Error e) {
            fail_if_reached(@"Preferred sender selection test failed: $(e.message)");
        }
    }

    void test_preferred_sender_does_not_fallback_sync() {
        var loop = new MainLoop();
        test_preferred_sender_does_not_fallback.begin((obj, res) => {
            test_preferred_sender_does_not_fallback.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_preferred_sender_does_not_fallback() {
        try {
            var manager = Dino.FileManager.create_for_tests();
            var http_sender = new TestRecordingFileSender(false, false, false, Dino.FileManager.HTTP_PROVIDER_ID, 100);
            var unavailable_jingle_sender = new TestUnavailableFileSender(Dino.FileManager.JINGLE_PROVIDER_ID, 50);
            manager.add_sender(http_sender);
            manager.add_sender(unavailable_jingle_sender);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            var file_transfer = create_send_file_transfer(account, Dino.Entities.Encryption.NONE, 4096);
            file_transfer.preferred_file_sender_id = Dino.FileManager.JINGLE_PROVIDER_ID;

            bool upload_failed = false;
            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                "*no sender/encryptor available*");
            try {
                yield manager.send_file_transport_pipeline_for_tests(conversation, file_transfer);
            } catch (Dino.FileSendError.UPLOAD_FAILED e) {
                upload_failed = true;
            }
            GLib.Test.assert_expected_messages();

            fail_if(!upload_failed,
                "explicit unavailable sender preference must fail instead of falling back");
            fail_if(http_sender.prepare_called || http_sender.send_called,
                "explicit sender preference must not fall back to a different available sender");
            fail_if(!unavailable_jingle_sender.can_send_called,
                "explicit sender preference must still check the requested sender availability");
            fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                "unavailable preferred sender must not complete through another transport");
        } catch (Error e) {
            fail_if_reached(@"Preferred sender no-fallback test failed: $(e.message)");
        }
    }

    void test_mixed_http_jingle_transfers_and_cancel_are_isolated_sync() {
        var loop = new MainLoop();
        test_mixed_http_jingle_transfers_and_cancel_are_isolated.begin((obj, res) => {
            test_mixed_http_jingle_transfers_and_cancel_are_isolated.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_mixed_http_jingle_transfers_and_cancel_are_isolated() {
        try {
            var manager = Dino.FileManager.create_for_tests();
            var http_sender = new TestControlledFileSender(Dino.FileManager.HTTP_PROVIDER_ID, 100);
            var jingle_sender = new TestControlledFileSender(Dino.FileManager.JINGLE_PROVIDER_ID, 50);
            manager.add_sender(http_sender);
            manager.add_sender(jingle_sender);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var http_conversation = new Dino.Entities.Conversation(
                new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            var first_jingle_conversation = new Dino.Entities.Conversation(
                new Xmpp.Jid("carol@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            var second_jingle_conversation = new Dino.Entities.Conversation(
                new Xmpp.Jid("dave@example.test"), account, Dino.Entities.Conversation.Type.CHAT);

            uint8[] http_payload = "mixed-http-payload".data;
            uint8[] first_jingle_payload = "mixed-jingle-payload-a".data;
            uint8[] second_jingle_payload = "mixed-jingle-payload-b".data;
            var http_transfer = create_send_file_transfer(account, Dino.Entities.Encryption.NONE, http_payload.length);
            var first_jingle_transfer = create_send_file_transfer(account, Dino.Entities.Encryption.NONE, first_jingle_payload.length);
            var second_jingle_transfer = create_send_file_transfer(account, Dino.Entities.Encryption.NONE, second_jingle_payload.length);
            http_transfer.counterpart = http_conversation.counterpart;
            first_jingle_transfer.counterpart = first_jingle_conversation.counterpart;
            second_jingle_transfer.counterpart = second_jingle_conversation.counterpart;
            http_transfer.file_name = "mixed-http.bin";
            first_jingle_transfer.file_name = "mixed-jingle-a.bin";
            second_jingle_transfer.file_name = "mixed-jingle-b.bin";
            http_transfer.input_stream = new MemoryInputStream.from_data(http_payload, null);
            first_jingle_transfer.input_stream = new MemoryInputStream.from_data(first_jingle_payload, null);
            second_jingle_transfer.input_stream = new MemoryInputStream.from_data(second_jingle_payload, null);
            http_transfer.preferred_file_sender_id = Dino.FileManager.HTTP_PROVIDER_ID;
            first_jingle_transfer.preferred_file_sender_id = Dino.FileManager.JINGLE_PROVIDER_ID;
            second_jingle_transfer.preferred_file_sender_id = Dino.FileManager.JINGLE_PROVIDER_ID;

            int completed = 0;
            int failures = 0;
            manager.send_file_transport_pipeline_for_tests.begin(http_conversation, http_transfer, (obj, res) => {
                try {
                    manager.send_file_transport_pipeline_for_tests.end(res);
                } catch (Error e) {
                    failures++;
                }
                completed++;
            });
            manager.send_file_transport_pipeline_for_tests.begin(first_jingle_conversation, first_jingle_transfer, (obj, res) => {
                try {
                    manager.send_file_transport_pipeline_for_tests.end(res);
                } catch (Error e) {
                    failures++;
                }
                completed++;
            });
            manager.send_file_transport_pipeline_for_tests.begin(second_jingle_conversation, second_jingle_transfer, (obj, res) => {
                try {
                    manager.send_file_transport_pipeline_for_tests.end(res);
                } catch (Error e) {
                    failures++;
                }
                completed++;
            });

            int wait_ticks = 0;
            while ((http_sender.active_count != 1 || jingle_sender.active_count != 2) && wait_ticks++ < 1000) {
                yield wait_one_test_tick();
            }
            fail_if(http_sender.active_count != 1 || jingle_sender.active_count != 2,
                "mixed transfer matrix must overlap one HTTP and two Jingle sends");

            first_jingle_transfer.cancellable.cancel();
            wait_ticks = 0;
            while (completed < 1 && wait_ticks++ < 1000) {
                yield wait_one_test_tick();
            }
            fail_if(completed != 1 || failures != 1,
                "cancelling one Jingle transfer must finish only that transfer with an error");
            fail_if(!http_sender.is_active(http_transfer),
                "the HTTP transfer must remain active after cancelling a Jingle transfer");
            fail_if(!jingle_sender.is_active(second_jingle_transfer),
                "the other Jingle transfer must remain active after cancelling its sibling");
            fail_if(http_transfer.cancellable.is_cancelled() || second_jingle_transfer.cancellable.is_cancelled(),
                "transfer cancellation must not leak to another transport or contact");

            http_sender.release(http_transfer);
            jingle_sender.release(second_jingle_transfer);
            wait_ticks = 0;
            while (completed < 3 && wait_ticks++ < 1000) {
                yield wait_one_test_tick();
            }
            fail_if(completed != 3 || failures != 1,
                "the unaffected HTTP and Jingle transfers must complete independently");
            fail_if(http_transfer.provider != Dino.FileManager.HTTP_PROVIDER_ID ||
                    first_jingle_transfer.provider != Dino.FileManager.JINGLE_PROVIDER_ID ||
                    second_jingle_transfer.provider != Dino.FileManager.JINGLE_PROVIDER_ID,
                "each mixed transfer must retain its independently selected transport");
            fail_if(http_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE ||
                    second_jingle_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "unaffected mixed transfers must reach COMPLETE");
            fail_if(first_jingle_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                "the cancelled Jingle transfer must not be marked complete");
            fail_if(!http_sender.has_payload(http_conversation.counterpart, http_payload) ||
                    !jingle_sender.has_payload(second_jingle_conversation.counterpart, second_jingle_payload),
                "each unaffected transport must read the payload assigned to its own contact");
        } catch (Error e) {
            fail_if_reached(@"Mixed HTTP/Jingle concurrency test failed: $(e.message)");
        }
    }

    private async void wait_one_test_tick() {
        SourceFunc callback = wait_one_test_tick.callback;
        Timeout.add(1, (owned) callback);
        yield;
    }

    void test_size_limits_filter_sender_encryption_viability_sync() {
        var loop = new MainLoop();
        test_size_limits_filter_sender_encryption_viability.begin((obj, res) => {
            test_size_limits_filter_sender_encryption_viability.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_size_limits_filter_sender_encryption_viability() {
        try {
            var manager = Dino.FileManager.create_for_tests();
            var http_sender = new TestRecordingFileSender(false, false, false, Dino.FileManager.HTTP_PROVIDER_ID, 100);
            var jingle_sender = new TestRecordingFileSender(false, false, false, Dino.FileManager.JINGLE_PROVIDER_ID, 50);
            manager.add_sender(http_sender);
            manager.add_sender(jingle_sender);
            manager.add_file_encryptor(new TestRequiredSenderFileEncryptor(Dino.FileManager.HTTP_PROVIDER_ID));

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);

            conversation.encryption = Dino.Entities.Encryption.NONE;
            HashMap<int, long> plain_limits = yield manager.get_file_size_limits(conversation, 4096);
            fail_if(plain_limits[Dino.FileManager.HTTP_PROVIDER_ID] < 4096,
                "plain HTTP sender must remain available in size limits");
            fail_if(plain_limits[Dino.FileManager.JINGLE_PROVIDER_ID] < 4096,
                "plain Jingle sender must remain available in size limits");

            conversation.encryption = Dino.Entities.Encryption.PGP;
            HashMap<int, long> encrypted_limits = yield manager.get_file_size_limits(conversation, 4096);
            fail_if(encrypted_limits[Dino.FileManager.HTTP_PROVIDER_ID] < 4096,
                "HTTP-bound encryptor must keep HTTP available in size limits");
            fail_if(encrypted_limits[Dino.FileManager.JINGLE_PROVIDER_ID] != -1,
                "HTTP-bound encryptor must hide incompatible Jingle sender in size limits");
        } catch (Error e) {
            fail_if_reached(@"Sender size-limit viability test failed: $(e.message)");
        }
    }

    void test_size_limits_report_fast_sender_before_slow_sender_sync() {
        var loop = new MainLoop();
        test_size_limits_report_fast_sender_before_slow_sender.begin((obj, res) => {
            test_size_limits_report_fast_sender_before_slow_sender.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_size_limits_report_fast_sender_before_slow_sender() {
        try {
            var manager = Dino.FileManager.create_for_tests();
            var http_sender = new TestRecordingFileSender(
                    false, false, false, Dino.FileManager.HTTP_PROVIDER_ID, 100);
            var slow_jingle_sender = new TestBlockingAvailabilityFileSender(
                    Dino.FileManager.JINGLE_PROVIDER_ID, 50, int.MAX);
            manager.add_sender(http_sender);
            manager.add_sender(slow_jingle_sender);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(
                    new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.NONE;

            bool completed = false;
            bool http_reported = false;
            bool jingle_reported = false;
            manager.get_file_size_limits_progressive.begin(conversation, 4096, (sender_id, limit) => {
                if (sender_id == Dino.FileManager.HTTP_PROVIDER_ID) {
                    http_reported = limit >= 4096;
                } else if (sender_id == Dino.FileManager.JINGLE_PROVIDER_ID) {
                    jingle_reported = limit >= 4096;
                }
            }, (obj, res) => {
                manager.get_file_size_limits_progressive.end(res);
                completed = true;
            });

            int wait_ticks = 0;
            while (!slow_jingle_sender.probe_started && wait_ticks++ < 1000) {
                yield wait_one_test_tick();
            }
            fail_if(!slow_jingle_sender.probe_started,
                    "the slow direct-transfer sender must reach its controlled probe");
            fail_if(!http_reported,
                    "the cached HTTP sender must be reported before a slow direct-transfer probe completes");
            fail_if(completed || jingle_reported,
                    "the aggregate result must remain pending until the slow sender resolves");

            slow_jingle_sender.release();
            wait_ticks = 0;
            while (!completed && wait_ticks++ < 1000) {
                yield wait_one_test_tick();
            }
            fail_if(!completed || !jingle_reported,
                    "the final result must include the direct-transfer sender after its probe resolves");
            fail_if(slow_jingle_sender.limit_probe_count != 1,
                    "each sender size limit must be probed exactly once per dialog");
            fail_if(slow_jingle_sender.can_send_count != 1,
                    "each sender availability must be probed exactly once per dialog");
        } catch (Error e) {
            fail_if_reached(@"Progressive sender-limit test failed: $(e.message)");
        }
    }

    void test_entity_info_has_feature_refreshes_unresolved_caps_hash_sync() {
        var loop = new MainLoop();
        test_entity_info_has_feature_refreshes_unresolved_caps_hash.begin((obj, res) => {
            test_entity_info_has_feature_refreshes_unresolved_caps_hash.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_entity_info_has_feature_refreshes_unresolved_caps_hash() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-entity-info-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Dino.Database? db = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "entity-info-unresolved-caps-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.EntityInfo.start(stream_interactor, (!) db);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            Xmpp.Jid peer_full_jid = new Xmpp.Jid("bob@example.test/DinoX.newcaps");
            string unresolved_caps_hash = "unresolved-caps-" + Uuid.string_random();
            ((!) db).entity.upsert()
                .value<int>(((!) db).entity.account_id, account.id, true)
                .value<int>(((!) db).entity.jid_id, ((!) db).get_jid_id(peer_full_jid), true)
                .value<string>(((!) db).entity.resource, peer_full_jid.resourcepart ?? "", true)
                .value<long>(((!) db).entity.last_seen, (long) (new DateTime.now_local()).to_unix())
                .value<string>(((!) db).entity.caps_hash, unresolved_caps_hash)
                .perform();

            stream_interactor.module_manager.initialize(account);
            var stream = new FileManagerJingleTestXmppStream(new Xmpp.Jid("example.test"));
            attach_service_discovery_modules_for_tests(stream_interactor, account, stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);
            stream_interactor.account_added(account);

            Dino.EntityInfo? entity_info = stream_interactor.get_module<Dino.EntityInfo>(Dino.EntityInfo.IDENTITY);
            fail_if(entity_info == null, "test setup must start EntityInfo");

            bool? has_feature = null;
            var feature_loop = new MainLoop();
            ((!) entity_info).has_feature.begin(account, peer_full_jid, Xmpp.Xep.JingleFileTransfer.Module.IDENTITY.ns, (obj, res) => {
                has_feature = ((!) entity_info).has_feature.end(res);
                feature_loop.quit();
            });

            StanzaNode? disco_request = wait_for_disco_info_request(stream, peer_full_jid, 1000);
            fail_if(disco_request == null,
                "EntityInfo must request disco#info when an entity row has an unresolved caps hash");
            stream.emit_iq_result(build_disco_info_result((!) disco_request, peer_full_jid, account.full_jid, {
                Xmpp.Xep.ServiceDiscovery.NS_URI_INFO,
                Xmpp.Xep.Jingle.Module.IDENTITY.ns,
                Xmpp.Xep.JingleFileTransfer.Module.IDENTITY.ns,
                Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns
            }));
            feature_loop.run();

            fail_if(has_feature != true,
                "EntityInfo must return the requested feature after refreshing an unresolved caps hash");
            int64 stored_features = ((!) db).entity_feature.select()
                .with<string>(((!) db).entity_feature.feature, "=", Xmpp.Xep.JingleFileTransfer.Module.IDENTITY.ns)
                .count();
            fail_if(stored_features == 0,
                "EntityInfo must persist refreshed disco features for the computed caps hash");
        } catch (Error e) {
            fail_if_reached(@"EntityInfo unresolved caps refresh test failed: $(e.message)");
        } finally {
            if (db != null) ((!) db).close();
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_external_encryptor_preprocesses_http_send_data_before_upload_sync() {
        var loop = new MainLoop();
        test_external_encryptor_preprocesses_http_send_data_before_upload.begin((obj, res) => {
            test_external_encryptor_preprocesses_http_send_data_before_upload.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_external_encryptor_preprocesses_http_send_data_before_upload() {
        try {
            var manager = Dino.FileManager.create_for_tests();
            var sender = new TestRecordingFileSender(false, true);
            var encryptor = new TestHttpSendDataFileEncryptor(Dino.Entities.Encryption.PGP, 4352);
            manager.add_sender(sender);
            manager.add_file_encryptor(encryptor);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            var file_transfer = create_send_file_transfer(account, Dino.Entities.Encryption.PGP, 4096);
            Gee.ArrayList<Dino.Entities.FileTransfer.Phase> phases = collect_phases(file_transfer);

            yield manager.send_file_transport_pipeline_for_tests(conversation, file_transfer);

            fail_if(!encryptor.preprocess_called,
                "external encryptor must preprocess HTTP send data before upload");
            fail_if(!sender.send_called,
                "HTTP-style sender must upload after compatible external encryptor preprocessing");
            fail_if(!sender.send_data_is_http,
                "sender upload must receive HTTP send data after external preprocessing");
            fail_if(!sender.send_data_encrypt_message,
                "PGP-style external encryptor must force body-url message encryption before upload");
            fail_if_not_eq_str(sender.send_data_url_down ?? "", "https://upload.example.test/payload.bin",
                "PGP-style external preprocessing must preserve the HTTP URL for encrypted body announcement");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.ENCRYPTING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "external encryption phase must precede HTTP send-data preparation");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "compatible external preprocessing must complete before upload starts");
        } catch (Error e) {
            fail_if_reached(@"HTTP send-data external preprocess test failed: $(e.message)");
        }
    }

    void test_external_encryptor_rejects_non_http_send_data_before_upload_sync() {
        var loop = new MainLoop();
        test_external_encryptor_rejects_non_http_send_data_before_upload.begin((obj, res) => {
            test_external_encryptor_rejects_non_http_send_data_before_upload.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_external_encryptor_rejects_non_http_send_data_before_upload() {
        try {
            var manager = Dino.FileManager.create_for_tests();
            var sender = new TestRecordingFileSender();
            var encryptor = new TestHttpSendDataFileEncryptor(Dino.Entities.Encryption.PGP, 4352);
            manager.add_sender(sender);
            manager.add_file_encryptor(encryptor);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            var file_transfer = create_send_file_transfer(account, Dino.Entities.Encryption.PGP, 4096);
            Gee.ArrayList<Dino.Entities.FileTransfer.Phase> phases = collect_phases(file_transfer);

            try {
                yield manager.send_file_transport_pipeline_for_tests(conversation, file_transfer);
                fail_if_reached("external encryptor must reject non-HTTP send data before upload");
            } catch (Dino.FileSendError.UPLOAD_FAILED e) {
                assert_true(true);
            }

            fail_if(!encryptor.preprocess_called,
                "external encryptor must inspect prepared send data before failing");
            fail_if(!sender.prepare_called,
                "sender prepare must run before external preprocess can reject incompatible send data");
            fail_if(sender.send_called,
                "sender upload must not run after external encryptor rejects non-HTTP send data");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.UPLOADING),
                "incompatible external preprocessing must fail before UPLOADING phase");
        } catch (Error e) {
            fail_if_reached(@"Non-HTTP send-data external preprocess test failed: $(e.message)");
        }
    }

    void test_send_file_publishes_local_copy_and_marks_failed_on_transport_error_sync() {
        var loop = new MainLoop();
        test_send_file_publishes_local_copy_and_marks_failed_on_transport_error.begin((obj, res) => {
            test_send_file_publishes_local_copy_and_marks_failed_on_transport_error.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_send_file_publishes_local_copy_and_marks_failed_on_transport_error() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string input_path = Path.build_filename(temp_dir, "payload.txt");
        Dino.Database? db = null;
        string? stored_path = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string plaintext_text = "outgoing local save before failed transport\n";
            uint8[] plaintext = plaintext_text.data;
            FileUtils.set_contents(input_path, plaintext_text);

            db = new Dino.Database(db_path, "send-pipeline-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);

            var file_encryption = new Dino.Security.FileEncryption("send-pipeline-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var sender = new TestFailingFileSender("synthetic transport failure");
            ((!) manager).add_sender(sender);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.NONE;

            Dino.Entities.FileTransfer? published_transfer = null;
            Dino.Entities.FileTransfer.Phase phase_at_publish = Dino.Entities.FileTransfer.Phase.NONE;
            bool transport_started_before_publish = false;
            bool configure_called = false;
            Gee.ArrayList<Dino.Entities.FileTransfer.Phase> phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                phase_at_publish = file_transfer.phase;
                transport_started_before_publish = sender.prepare_called || sender.send_called;
                fail_if(file_transfer.id == -1, "received_file must publish a persisted outgoing transfer");
                fail_if(file_transfer.path == null, "received_file must publish the saved local outgoing path");
                stored_path = file_transfer.path;
                File? published_file = file_transfer.get_file();
                fail_if(published_file == null || !((!) published_file).query_exists(),
                    "received_file must publish only after the encrypted local copy exists");
            });

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING, "*Send file error: synthetic transport failure*");
            yield ((!) manager).send_file(File.new_for_path(input_path), conversation, (file_transfer) => {
                configure_called = true;
                fail_if(file_transfer.id != -1, "configure must run before outgoing transfer persistence");
                fail_if(file_transfer.path != null, "configure must run before local outgoing path publication");
                fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.PREPARING,
                    "configure must observe the prepared transfer before local storage starts");
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            });
            GLib.Test.assert_expected_messages();

            fail_if(!configure_called, "send_file must expose the prepared transfer before local storage");
            fail_if(published_transfer == null, "send_file must publish the locally saved transfer before transport");
            var file_transfer = (!) published_transfer;
            fail_if(transport_started_before_publish,
                "local publication must happen before slot preparation or upload starts");
            fail_if(phase_at_publish != Dino.Entities.FileTransfer.Phase.STORING,
                "published outgoing transfer must still be in the local store phase before transport starts");
            fail_if(file_transfer.id == -1, "locally saved outgoing transfer must be persisted before transport");
            fail_if(file_transfer.path == null, "locally saved outgoing transfer must expose a storage path before transport");
            fail_if(!sender.prepare_called, "send_file must reach transport slot preparation after local save");
            fail_if(!sender.send_called, "send_file must reach transport upload after local save");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "transport failure must mark the transfer as failed");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "transport failure must persist the failed transfer state in memory");
            fail_if(file_transfer.phase_error == null || !((!) file_transfer.phase_error).contains("synthetic transport failure"),
                "transport failure must keep the sender error message on the transfer");
            fail_if(!file_transfer.input_stream.is_closed(),
                "transport failure must close the upload input stream");
            bool read_after_close_failed = false;
            try {
                uint8[] probe = new uint8[1];
                file_transfer.input_stream.read(probe);
            } catch (Error e) {
                read_after_close_failed = true;
            }
            fail_if(!read_after_close_failed,
                "closed upload input stream must reject reads after transport failure");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.STORING, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                "local store phase must complete before transport slot preparation");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT, Dino.Entities.FileTransfer.Phase.UPLOADING,
                "slot preparation must complete before upload starts");
            assert_phase_order(phases, Dino.Entities.FileTransfer.Phase.UPLOADING, Dino.Entities.FileTransfer.Phase.FAILED,
                "transport upload failure must become the final failed phase");
            fail_if(phases.contains(Dino.Entities.FileTransfer.Phase.COMPLETE),
                "failed transport must not emit a complete phase");

            File? stored_file_opt = file_transfer.get_file();
            fail_if(stored_file_opt == null, "published transfer must resolve through FileTransfer.get_file()");
            File stored_file = (!) stored_file_opt;
            fail_if(!stored_file.query_exists(), "failed transport must not remove the already published local copy");

            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "transport failure must persist the transfer as failed in the database");

            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream(stored_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal(plaintext, decrypted),
                "published local copy must decrypt to the original outgoing file after transport failure");
        } catch (Error e) {
            fail_if_reached(@"send_file transport failure propagation test failed: $(e.message)");
        } finally {
            if (db != null) {
                ((!) db).close();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_external_plaintext_source_under_data_path_is_not_decrypted_sync() {
        var loop = new MainLoop();
        test_outgoing_file_source.begin(false, (obj, res) => {
            test_outgoing_file_source.end(res);
            loop.quit();
        });
        loop.run();
    }

    void test_dinox_managed_storage_source_is_decoded_sync() {
        var loop = new MainLoop();
        test_outgoing_file_source.begin(true, (obj, res) => {
            test_outgoing_file_source.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_outgoing_file_source(bool dinox_managed_storage) {
        string test_id = Uuid.string_random();
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + test_id);
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string source_dir = Path.build_filename(Dino.get_storage_dir(), "source-mode-test-" + test_id);
        string input_path = Path.build_filename(source_dir, "source.txt");
        Dino.Database? db = null;
        string? stored_path = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            DirUtils.create_with_parents(source_dir, 0700);

            string plaintext_text = dinox_managed_storage
                ? "explicit DinoX-managed storage source\n"
                : "external plaintext below DinoX data path\n";
            uint8[] plaintext = plaintext_text.data;
            var file_encryption = new Dino.Security.FileEncryption("outgoing-source-mode-test");
            File input_file = File.new_for_path(input_path);

            if (dinox_managed_storage) {
                InputStream plaintext_input = new MemoryInputStream.from_data(plaintext, null);
                OutputStream protected_output = input_file.create(FileCreateFlags.PRIVATE);
                yield file_encryption.encrypt_stream(plaintext_input, protected_output, null);
                protected_output.close();
                plaintext_input.close();
            } else {
                FileUtils.set_contents(input_path, plaintext_text);
            }

            db = new Dino.Database(db_path, "outgoing-source-mode-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var sender = new TestRecordingFileSender(false, false, true);
            ((!) manager).add_sender(sender);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var conversation = new Dino.Entities.Conversation(
                    new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.NONE;

            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
            });

            if (dinox_managed_storage) {
                yield ((!) manager).send_file_with_source(
                        input_file, conversation, Dino.OutgoingFileSource.DINOX_MANAGED_STORAGE);
            } else {
                // The default is explicit external plaintext. Its location must
                // not make FileManager reinterpret the bytes as locally protected.
                yield ((!) manager).send_file(input_file, conversation);
            }

            fail_if(published_transfer == null,
                dinox_managed_storage
                    ? "explicit DinoX-managed storage source must be decoded and published"
                    : "external plaintext below DinoX data path must be published without decryption");
            fail_if(!sender.send_called, "explicit outgoing source mode must reach the transport sender");
            fail_if(sender.uploaded_payload == null || !bytes_equal(plaintext, (!) sender.uploaded_payload),
                dinox_managed_storage
                    ? "DINOX_MANAGED_STORAGE must decode the source before transport"
                    : "EXTERNAL_PLAINTEXT must preserve source bytes regardless of path");
        } catch (Error e) {
            fail_if_reached(@"Explicit outgoing file source test failed: $(e.message)");
        } finally {
            if (db != null) ((!) db).close();
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            FileUtils.remove(input_path);
            DirUtils.remove(source_dir);
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_sticker_managed_child_source() {
        string root = Path.build_filename(Environment.get_tmp_dir(), "dinox", "stickers");
        string child = Path.build_filename(root, "pack", "sticker.webp");
        fail_if(Dino.Stickers.get_outgoing_source_for_path(child, root) !=
                Dino.OutgoingFileSource.DINOX_MANAGED_STORAGE,
                "a sticker cache child must be decoded as DinoX-managed storage");
    }

    void test_sticker_legacy_external_source() {
        string root = Path.build_filename(Environment.get_tmp_dir(), "dinox", "stickers");
        string external = Path.build_filename(Environment.get_tmp_dir(), "pictures", "sticker.webp");
        fail_if(Dino.Stickers.get_outgoing_source_for_path(external, root) !=
                Dino.OutgoingFileSource.EXTERNAL_PLAINTEXT,
                "legacy sticker rows that reference an external original must stay plaintext");
    }

    void test_sticker_prefix_collision_source() {
        string root = Path.build_filename(Environment.get_tmp_dir(), "dinox", "stickers");
        string sibling = Path.build_filename(Environment.get_tmp_dir(), "dinox", "stickers-old", "sticker.webp");
        fail_if(Dino.Stickers.get_outgoing_source_for_path(sibling, root) !=
                Dino.OutgoingFileSource.EXTERNAL_PLAINTEXT,
                "a lexical sticker-directory prefix collision must not be treated as managed storage");
    }

    void test_send_file_unencrypted_success_publishes_complete_transfer_sync() {
        var loop = new MainLoop();
        test_send_file_unencrypted_success_publishes_complete_transfer.begin((obj, res) => {
            test_send_file_unencrypted_success_publishes_complete_transfer.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_send_file_unencrypted_success_publishes_complete_transfer() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string input_path = Path.build_filename(temp_dir, "payload-success.txt");
        Dino.Database? db = null;
        string? stored_path = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string plaintext_text = "unencrypted outgoing success matrix\n";
            uint8[] plaintext = plaintext_text.data;
            FileUtils.set_contents(input_path, plaintext_text);

            db = new Dino.Database(db_path, "send-success-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);

            var file_encryption = new Dino.Security.FileEncryption("send-success-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var sender = new TestRecordingFileSender(false, false, true, Dino.FileManager.JINGLE_PROVIDER_ID);
            ((!) manager).add_sender(sender);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.NONE;

            Dino.Entities.FileTransfer? published_transfer = null;
            bool transport_started_before_publish = false;
            Gee.ArrayList<Dino.Entities.FileTransfer.Phase> phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                transport_started_before_publish = sender.prepare_called || sender.send_called;
                fail_if(file_transfer.id == -1, "received_file must publish a persisted outgoing transfer");
                fail_if(file_transfer.path == null, "received_file must publish the saved local outgoing path");
                stored_path = file_transfer.path;
                File? published_file = file_transfer.get_file();
                fail_if(published_file == null || !((!) published_file).query_exists(),
                    "received_file must publish only after the encrypted local copy exists");
            });

            yield ((!) manager).send_file(File.new_for_path(input_path), conversation, (file_transfer) => {
                fail_if(file_transfer.id != -1, "configure must run before outgoing transfer persistence");
                fail_if(file_transfer.path != null, "configure must run before local outgoing path publication");
                fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.PREPARING,
                    "configure must observe the prepared transfer before local storage starts");
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            });

            fail_if(published_transfer == null, "send_file success must publish the locally saved transfer");
            var file_transfer = (!) published_transfer;
            fail_if(transport_started_before_publish,
                "local publication must happen before slot preparation or upload starts");
            fail_if(!sender.prepare_called, "successful send_file must prepare transport send data");
            fail_if(!sender.send_called, "successful send_file must call the selected transport sender");
            fail_if(sender.uploaded_payload == null || !bytes_equal(plaintext, (!) sender.uploaded_payload),
                "successful unencrypted send must expose the original bytes to the selected transport sender");
            fail_if(file_transfer.provider != Dino.FileManager.JINGLE_PROVIDER_ID,
                "successful send_file must keep the selected sender provider id in memory");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful send_file must finish in COMPLETE phase");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful send_file must finish with COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful send_file must not retain a phase error");
            fail_if(!file_transfer.input_stream.is_closed(),
                "successful send_file must close the upload input stream");
            assert_phase_sequence(phases, {
                    Dino.Entities.FileTransfer.Phase.PREPARING,
                    Dino.Entities.FileTransfer.Phase.STORING,
                    Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                    Dino.Entities.FileTransfer.Phase.UPLOADING,
                    Dino.Entities.FileTransfer.Phase.COMPLETE
                }, "successful unencrypted send must expose the exact runtime phase sequence");

            File? stored_file_opt = file_transfer.get_file();
            fail_if(stored_file_opt == null, "published transfer must resolve through FileTransfer.get_file()");
            File stored_file = (!) stored_file_opt;
            fail_if(!stored_file.query_exists(), "successful send must keep the published local copy");
            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "successful send must persist the transfer as complete in the database");
            assert_persisted_transfer_provider((!) db, file_transfer, Dino.FileManager.JINGLE_PROVIDER_ID,
                "successful send must persist the selected sender provider id in the database");

            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream(stored_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal(plaintext, decrypted),
                "successful send local copy must decrypt to the original outgoing file");
        } catch (Error e) {
            fail_if_reached(@"send_file success matrix test failed: $(e.message)");
        } finally {
            if (db != null) {
                ((!) db).close();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_send_file_unencrypted_cancel_after_local_store_marks_failed_sync() {
        var loop = new MainLoop();
        test_send_file_unencrypted_cancel_after_local_store_marks_failed.begin((obj, res) => {
            test_send_file_unencrypted_cancel_after_local_store_marks_failed.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_send_file_unencrypted_cancel_after_local_store_marks_failed() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string input_path = Path.build_filename(temp_dir, "payload-cancel.txt");
        Dino.Database? db = null;
        string? stored_path = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string plaintext_text = "unencrypted outgoing cancel matrix\n";
            uint8[] plaintext = plaintext_text.data;
            FileUtils.set_contents(input_path, plaintext_text);

            db = new Dino.Database(db_path, "send-cancel-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);

            var file_encryption = new Dino.Security.FileEncryption("send-cancel-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var sender = new TestCancellingFileSender();
            ((!) manager).add_sender(sender);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.NONE;

            Dino.Entities.FileTransfer? published_transfer = null;
            bool transport_started_before_publish = false;
            Gee.ArrayList<Dino.Entities.FileTransfer.Phase> phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                transport_started_before_publish = sender.prepare_called || sender.send_called;
                fail_if(file_transfer.id == -1, "received_file must publish a persisted outgoing transfer");
                fail_if(file_transfer.path == null, "received_file must publish the saved local outgoing path");
                stored_path = file_transfer.path;
                File? published_file = file_transfer.get_file();
                fail_if(published_file == null || !((!) published_file).query_exists(),
                    "received_file must publish only after the encrypted local copy exists");
            });

            yield ((!) manager).send_file(File.new_for_path(input_path), conversation, (file_transfer) => {
                fail_if(file_transfer.id != -1, "configure must run before outgoing transfer persistence");
                fail_if(file_transfer.path != null, "configure must run before local outgoing path publication");
                fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.PREPARING,
                    "configure must observe the prepared transfer before local storage starts");
                phases.add(file_transfer.phase);
                file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
            });

            fail_if(published_transfer == null, "send_file cancellation after local store must publish the local transfer first");
            var file_transfer = (!) published_transfer;
            fail_if(transport_started_before_publish,
                "local publication must happen before slot preparation starts");
            fail_if(!sender.prepare_called, "cancelled send_file must reach transport slot preparation");
            fail_if(sender.send_called, "cancellation during slot preparation must not start upload");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "cancelled send_file must finish in FAILED phase");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "cancelled send_file must finish with FAILED state");
            fail_if(file_transfer.phase_error == null || ((!) file_transfer.phase_error) != "cancelled",
                "cancelled send_file must keep the canonical cancelled phase error");
            fail_if(!file_transfer.input_stream.is_closed(),
                "cancelled send_file must close the upload input stream");
            assert_phase_sequence(phases, {
                    Dino.Entities.FileTransfer.Phase.PREPARING,
                    Dino.Entities.FileTransfer.Phase.STORING,
                    Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                    Dino.Entities.FileTransfer.Phase.FAILED
                }, "cancelled unencrypted send must expose the exact runtime phase sequence");

            File? stored_file_opt = file_transfer.get_file();
            fail_if(stored_file_opt == null, "published transfer must resolve through FileTransfer.get_file()");
            File stored_file = (!) stored_file_opt;
            fail_if(!stored_file.query_exists(), "cancelled transport must not remove the already published local copy");
            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "cancelled transport must persist the transfer as failed in the database");

            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream(stored_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal(plaintext, decrypted),
                "cancelled send local copy must decrypt to the original outgoing file");
        } catch (Error e) {
            fail_if_reached(@"send_file cancel matrix test failed: $(e.message)");
        } finally {
            if (db != null) {
                ((!) db).close();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_retry_send_after_restart_uses_persisted_local_copy_sync() {
        var loop = new MainLoop();
        test_retry_send_after_restart_uses_persisted_local_copy.begin((obj, res) => {
            test_retry_send_after_restart_uses_persisted_local_copy.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_retry_send_after_restart_uses_persisted_local_copy() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string input_path = Path.build_filename(temp_dir, "payload-retry.txt");
        Dino.Database? db = null;
        string? stored_path = null;
        Dino.Security.FileEncryption file_encryption = new Dino.Security.FileEncryption("send-retry-test");
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string plaintext_text = "retry must use the persisted outgoing copy\n";
            uint8[] plaintext = plaintext_text.data;
            FileUtils.set_contents(input_path, plaintext_text);

            db = new Dino.Database(db_path, "send-retry-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);

            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var failing_sender = new TestFailingFileSender("synthetic first upload failure");
            ((!) manager).add_sender(failing_sender);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.NONE;
            conversation.persist((!) db);

            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
            });

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING, "*Send file error: synthetic first upload failure*");
            yield ((!) manager).send_file(File.new_for_path(input_path), conversation);
            GLib.Test.assert_expected_messages();

            fail_if(published_transfer == null, "first failed send must publish the local outgoing transfer");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "first failed send must leave a retryable failed transfer");
            fail_if(!file_transfer.can_retry_send_attempt(),
                "failed sent transfer with local copy must become retryable");
            fail_if(stored_path == null || ((!) stored_path) == "",
                "failed sent transfer must keep a persisted local storage path");
            string original_stored_path = (!) stored_path;
            int original_transfer_id = file_transfer.id;

            FileUtils.remove(input_path);

            ((!) db).close();
            db = null;

            db = new Dino.Database(db_path, "send-retry-test");
            stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.MessageStorage.start(stream_interactor, (!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);
            Dino.MessageProcessor.start(stream_interactor, (!) db);
            Dino.EntityInfo.start(stream_interactor, (!) db);
            Dino.RosterManager.start(stream_interactor, (!) db);
            Dino.Calls.start(stream_interactor, (!) db);
            Dino.ConversationManager.start(stream_interactor, (!) db);
            Dino.PresenceManager.start(stream_interactor, (!) db);
            Dino.MucManager.start(stream_interactor);
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "restart setup must start FileManager");

            var accounts = ((!) db).get_accounts();
            fail_if(accounts.size != 1, "restart setup must load the persisted account");
            Dino.Entities.Account restarted_account = accounts[0];
            stream_interactor.module_manager.initialize(restarted_account);
            stream_interactor.account_added(restarted_account);

            var conversation_manager = stream_interactor.get_module<Dino.ConversationManager>(Dino.ConversationManager.IDENTITY);
            fail_if(conversation_manager == null, "restart setup must start ConversationManager");
            Dino.Entities.Conversation? reloaded_conversation = ((!) conversation_manager).get_conversation(
                new Xmpp.Jid("bob@example.test"), restarted_account, Dino.Entities.Conversation.Type.CHAT);
            fail_if(reloaded_conversation == null, "restart setup must reload the persisted conversation");

            var transfer_storage = stream_interactor.get_module<Dino.FileTransferStorage>(Dino.FileTransferStorage.IDENTITY);
            fail_if(transfer_storage == null, "restart setup must start FileTransferStorage");
            Dino.Entities.FileTransfer? reloaded_file_transfer = ((!) transfer_storage).get_file_by_id(
                original_transfer_id, (!) reloaded_conversation);
            fail_if(reloaded_file_transfer == null, "restart setup must reload the failed outgoing transfer");
            file_transfer = (!) reloaded_file_transfer;
            fail_if(!file_transfer.can_retry_send_attempt(),
                "reloaded failed sent transfer with local copy must remain retryable");

            var retry_sender = new TestRecordingFileSender(false, false, true, Dino.FileManager.JINGLE_PROVIDER_ID, 300);
            ((!) manager).add_sender(retry_sender);
            Gee.ArrayList<Dino.Entities.FileTransfer.Phase> retry_phases = collect_phases(file_transfer);

            yield ((!) manager).retry_send_file(file_transfer);

            fail_if(!retry_sender.prepare_called, "retry must prepare a new transport send");
            fail_if(!retry_sender.send_called, "retry must upload using the selected retry sender");
            fail_if(retry_sender.uploaded_payload == null || !bytes_equal(plaintext, (!) retry_sender.uploaded_payload),
                "public retry after restart must read the original plaintext from the persisted local copy");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful retry must finish in COMPLETE phase");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful retry must finish with COMPLETE state");
            fail_if(file_transfer.phase_error != null,
                "successful retry must clear the previous transport failure text");
            fail_if(file_transfer.path != original_stored_path,
                "successful retry must keep the existing local at-rest copy path");
            fail_if(file_transfer.provider != Dino.FileManager.JINGLE_PROVIDER_ID,
                "successful retry must persist the selected retry sender provider");
            assert_phase_sequence(retry_phases, {
                    Dino.Entities.FileTransfer.Phase.PREPARING,
                    Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
                    Dino.Entities.FileTransfer.Phase.UPLOADING,
                    Dino.Entities.FileTransfer.Phase.COMPLETE
                }, "successful retry must expose the upload-only runtime phase sequence");
            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "successful retry must persist COMPLETE state");
            assert_persisted_transfer_provider((!) db, file_transfer, Dino.FileManager.JINGLE_PROVIDER_ID,
                "successful public retry after restart must persist the selected provider id");

            File? stored_file = file_transfer.get_file();
            fail_if(stored_file == null || !((!) stored_file).query_exists(),
                "successful retry must keep the existing encrypted local copy");
            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal(plaintext, decrypted),
                "local copy after retry must still decrypt to the original outgoing file");
        } catch (Error e) {
                fail_if_reached(@"send retry after restart from persisted copy test failed: $(e.message)");
        } finally {
            if (db != null) {
                ((!) db).close();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_retry_send_cancel_keeps_local_copy_failed_sync() {
        var loop = new MainLoop();
        test_retry_send_cancel_keeps_local_copy_failed.begin((obj, res) => {
            test_retry_send_cancel_keeps_local_copy_failed.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_retry_send_cancel_keeps_local_copy_failed() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string input_path = Path.build_filename(temp_dir, "payload-retry-cancel.txt");
        Dino.Database? db = null;
        string? stored_path = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            string plaintext_text = "retry cancellation must keep the local copy\n";
            uint8[] plaintext = plaintext_text.data;
            FileUtils.set_contents(input_path, plaintext_text);

            db = new Dino.Database(db_path, "send-retry-cancel-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);

            var file_encryption = new Dino.Security.FileEncryption("send-retry-cancel-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var failing_sender = new TestFailingFileSender("synthetic retry setup failure");
            ((!) manager).add_sender(failing_sender);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            conversation.encryption = Dino.Entities.Encryption.NONE;

            Dino.Entities.FileTransfer? published_transfer = null;
            ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                stored_path = file_transfer.path;
            });

            GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING, "*Send file error: synthetic retry setup failure*");
            yield ((!) manager).send_file(File.new_for_path(input_path), conversation);
            GLib.Test.assert_expected_messages();

            fail_if(published_transfer == null, "setup send must publish a failed local transfer");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "setup send must leave the transfer failed");
            fail_if(stored_path == null || ((!) stored_path) == "",
                "setup send must keep a local storage path");
            string original_stored_path = (!) stored_path;

            var cancelling_sender = new TestCancellingFileSender(300);
            ((!) manager).add_sender(cancelling_sender);

            yield ((!) manager).retry_send_file_for_tests(conversation, file_transfer);

            fail_if(!cancelling_sender.prepare_called, "cancel retry must reach slot preparation");
            fail_if(cancelling_sender.send_called, "cancel retry must not start upload after cancellation");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "cancelled retry must finish in FAILED phase");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "cancelled retry must keep FAILED state");
            fail_if(file_transfer.phase_error == null || ((!) file_transfer.phase_error) != "cancelled",
                "cancelled retry must keep the canonical cancelled phase error");
            fail_if(file_transfer.path != original_stored_path,
                "cancelled retry must keep the existing local at-rest copy path");
            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                "cancelled retry must keep the persisted transfer failed");

            File? stored_file = file_transfer.get_file();
            fail_if(stored_file == null || !((!) stored_file).query_exists(),
                "cancelled retry must not remove the encrypted local copy");
            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal(plaintext, decrypted),
                "local copy after cancelled retry must still decrypt to the original outgoing file");
        } catch (Error e) {
            fail_if_reached(@"send retry cancellation test failed: $(e.message)");
        } finally {
            if (db != null) {
                ((!) db).close();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            cleanup_export_test_dir(temp_dir);
        }
    }

    Dino.Entities.FileTransfer create_send_file_transfer(Dino.Entities.Account account, Dino.Entities.Encryption encryption, int64 size) throws Error {
        var file_transfer = new Dino.Entities.FileTransfer();
        file_transfer.account = account;
        file_transfer.counterpart = new Xmpp.Jid("bob@example.test");
        file_transfer.ourpart = account.full_jid;
        file_transfer.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        file_transfer.time = new DateTime.now_utc();
        file_transfer.local_time = new DateTime.now_utc();
        file_transfer.file_name = "payload.bin";
        file_transfer.mime_type = "application/octet-stream";
        file_transfer.size = size;
        file_transfer.encryption = encryption;
        file_transfer.input_stream = new MemoryInputStream.from_data("payload".data);
        return file_transfer;
    }

    Gee.ArrayList<Dino.Entities.FileTransfer.Phase> collect_phases(Dino.Entities.FileTransfer file_transfer) {
        var phases = new Gee.ArrayList<Dino.Entities.FileTransfer.Phase>();
        file_transfer.notify["phase"].connect(() => phases.add(file_transfer.phase));
        return phases;
    }

    void assert_phase_order(Gee.List<Dino.Entities.FileTransfer.Phase> phases, Dino.Entities.FileTransfer.Phase before, Dino.Entities.FileTransfer.Phase after, string reason) {
        int before_index = -1;
        int after_index = -1;
        for (int i = 0; i < phases.size; i++) {
            if (phases[i] == before && before_index < 0) before_index = i;
            if (phases[i] == after && after_index < 0) after_index = i;
        }
        fail_if(before_index < 0 || after_index < 0 || before_index >= after_index, reason);
    }

    void assert_phase_sequence(Gee.List<Dino.Entities.FileTransfer.Phase> phases, Dino.Entities.FileTransfer.Phase[] expected_phases, string reason) {
        fail_if(phases.size != expected_phases.length, reason);
        for (int i = 0; i < expected_phases.length; i++) {
            fail_if(phases[i] != expected_phases[i], reason);
        }
    }

    void assert_persisted_transfer_state(Dino.Database db, Dino.Entities.FileTransfer file_transfer, Dino.Entities.FileTransfer.State expected_state, string reason) {
        Qlite.RowOption row = db.file_transfer.select()
                .with(db.file_transfer.id, "=", file_transfer.id)
                .single()
                .row();
        fail_if(!row.is_present(), "published outgoing transfer must be present in the database");
        var persisted_state = (Dino.Entities.FileTransfer.State) ((!) row.inner)[db.file_transfer.state];
        fail_if(persisted_state != expected_state, reason);
    }

    void assert_persisted_transfer_provider(Dino.Database db, Dino.Entities.FileTransfer file_transfer, int expected_provider, string reason) {
        Qlite.RowOption row = db.file_transfer.select()
                .with(db.file_transfer.id, "=", file_transfer.id)
                .single()
                .row();
        fail_if(!row.is_present(), "published outgoing transfer must be present in the database");
        int persisted_provider = ((!) row.inner)[db.file_transfer.provider];
        fail_if(persisted_provider != expected_provider, reason);
    }

    void test_transfer_worker_runs_jobs_off_main_thread_sync() {
        var loop = new MainLoop();
        test_transfer_worker_runs_jobs_off_main_thread.begin((obj, res) => {
            test_transfer_worker_runs_jobs_off_main_thread.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_transfer_worker_runs_jobs_off_main_thread() {
        int64 main_thread_id = (int64) Thread.self<void*>();
        int64 worker_thread_id = main_thread_id;
        bool ran = false;

        try {
            yield Dino.FileTransferWorker.run("test-worker-thread", () => {
                worker_thread_id = (int64) Thread.self<void*>();
                ran = true;
            });
        } catch (Error e) {
            fail_if_reached(@"Transfer worker test job failed: $(e.message)");
        }

        fail_if(!ran, "transfer worker must execute the queued job");
        fail_if(worker_thread_id == main_thread_id,
            "transfer worker jobs must run outside the main test thread");
    }

    void test_transfer_worker_resumes_on_caller_context_sync() {
        var context = new MainContext();
        var loop = new MainLoop(context);
        bool completed = false;
        bool timed_out = false;

        context.push_thread_default();
        test_transfer_worker_resumes_on_caller_context.begin(context, (obj, res) => {
            test_transfer_worker_resumes_on_caller_context.end(res);
            completed = true;
            loop.quit();
        });

        var timeout = new TimeoutSource(5000);
        timeout.set_callback(() => {
            timed_out = true;
            loop.quit();
            return Source.REMOVE;
        });
        timeout.attach(context);
        context.pop_thread_default();

        loop.run();

        fail_if(timed_out, "transfer worker must resume on the caller context");
        fail_if(!completed, "transfer worker async callback must complete");
    }

    async void test_transfer_worker_resumes_on_caller_context(MainContext expected_context) {
        bool ran = false;

        try {
            yield Dino.FileTransferWorker.run("test-worker-context", () => {
                ran = true;
            });
        } catch (Error e) {
            fail_if_reached(@"Transfer worker context test job failed: $(e.message)");
        }

        fail_if(!ran, "transfer worker must execute the context test job");
        fail_if(!expected_context.is_owner(), "transfer worker must resume on the caller context");
    }

    void test_transfer_worker_propagates_worker_errors_sync() {
        var loop = new MainLoop();
        test_transfer_worker_propagates_worker_errors.begin((obj, res) => {
            test_transfer_worker_propagates_worker_errors.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_transfer_worker_propagates_worker_errors() {
        bool failed = false;
        try {
            yield Dino.FileTransferWorker.run("test-worker-error", () => {
                throw new IOError.FAILED("intentional worker failure");
            });
        } catch (IOError.FAILED e) {
            failed = true;
            fail_if(!e.message.contains("intentional worker failure"),
                "transfer worker must preserve the original error message");
        } catch (Error e) {
            fail_if_reached(@"Unexpected transfer worker error type: $(e.message)");
        }

        fail_if(!failed, "transfer worker must propagate worker errors to async callers");
    }

    void test_transfer_worker_publish_lane_resumes_on_caller_context_sync() {
        var context = new MainContext();
        var loop = new MainLoop(context);
        bool completed = false;
        bool timed_out = false;

        context.push_thread_default();
        test_transfer_worker_publish_lane_resumes_on_caller_context.begin(context, (obj, res) => {
            test_transfer_worker_publish_lane_resumes_on_caller_context.end(res);
            completed = true;
            loop.quit();
        });

        var timeout = new TimeoutSource(5000);
        timeout.set_callback(() => {
            timed_out = true;
            loop.quit();
            return Source.REMOVE;
        });
        timeout.attach(context);
        context.pop_thread_default();

        loop.run();

        fail_if(timed_out, "transfer publish worker must resume on the caller context");
        fail_if(!completed, "transfer publish worker async callback must complete");
    }

    async void test_transfer_worker_publish_lane_resumes_on_caller_context(MainContext expected_context) {
        int64 main_thread_id = (int64) Thread.self<void*>();
        int64 publish_thread_id = main_thread_id;
        bool ran = false;

        try {
            yield Dino.FileTransferWorker.run_publish("test-publish-context", () => {
                publish_thread_id = (int64) Thread.self<void*>();
                ran = true;
            });
        } catch (Error e) {
            fail_if_reached(@"Transfer publish worker context test job failed: $(e.message)");
        }

        fail_if(!ran, "transfer publish worker must execute the context test job");
        fail_if(publish_thread_id == main_thread_id,
            "transfer publish worker jobs must run outside the main test thread");
        fail_if(!expected_context.is_owner(), "transfer publish worker must resume on the caller context");
    }

    void test_transfer_worker_publish_lane_not_blocked_by_default_lane_sync() {
        int64 main_thread_id = (int64) Thread.self<void*>();
        int64 publish_thread_id = main_thread_id;
        Mutex mutex = Mutex();
        Cond cond = Cond();
        bool default_job_started = false;
        bool release_default_job = false;
        bool publish_completed = false;
        bool publish_failed = false;
        bool timed_out = false;

        Dino.FileTransferWorker.run.begin("test-default-lane-blocker", () => {
            mutex.lock();
            default_job_started = true;
            cond.signal();
            while (!release_default_job) {
                cond.wait(mutex);
            }
            mutex.unlock();
        }, (obj, res) => {
            try {
                Dino.FileTransferWorker.run.end(res);
            } catch (Error e) {
                fail_if_reached(@"Default worker blocker failed: $(e.message)");
            }
        });

        mutex.lock();
        while (!default_job_started) {
            cond.wait(mutex);
        }
        mutex.unlock();

        var loop = new MainLoop();
        var timeout = new TimeoutSource(5000);
        timeout.set_callback(() => {
            timed_out = true;
            loop.quit();
            return Source.REMOVE;
        });
        uint timeout_id = timeout.attach(null);

        Dino.FileTransferWorker.run_publish.begin("test-publish-not-blocked", () => {
            publish_thread_id = (int64) Thread.self<void*>();
        }, (obj, res) => {
            try {
                Dino.FileTransferWorker.run_publish.end(res);
                publish_completed = true;
            } catch (Error e) {
                publish_failed = true;
            }
            loop.quit();
        });

        loop.run();

        if (!timed_out) {
            Source.remove(timeout_id);
        }

        mutex.lock();
        release_default_job = true;
        cond.signal();
        mutex.unlock();

        var drain_loop = new MainLoop();
        Dino.FileTransferWorker.run.begin("test-default-lane-drain", () => {}, (obj, res) => {
            try {
                Dino.FileTransferWorker.run.end(res);
            } catch (Error e) {
                fail_if_reached(@"Default worker drain failed: $(e.message)");
            }
            drain_loop.quit();
        });
        drain_loop.run();

        fail_if(timed_out, "publish lane must not wait for a blocked default worker lane");
        fail_if(publish_failed, "publish lane job must not fail");
        fail_if(!publish_completed, "publish lane job must complete before default lane is released");
        fail_if(publish_thread_id == main_thread_id,
            "transfer publish worker jobs must run outside the main test thread");
    }

    void test_plaintext_lease_cleanup_removes_stale_tree() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string root = Path.build_filename(temp_dir, "dinox", "temp_plaintext");
        string purpose_dir = Path.build_filename(root, "open");
        string lease_dir = Path.build_filename(purpose_dir, Uuid.string_random());
        string stale_path = Path.build_filename(lease_dir, "report.txt");
        string pgp_send_purpose_dir = Path.build_filename(root, "pgp-send");
        string pgp_send_lease_dir = Path.build_filename(pgp_send_purpose_dir, Uuid.string_random());
        string pgp_send_stale_path = Path.build_filename(pgp_send_lease_dir, "input");

        try {
            DirUtils.create_with_parents(lease_dir, 0700);
            FileUtils.set_contents(stale_path, "stale plaintext\n");
            DirUtils.create_with_parents(pgp_send_lease_dir, 0700);
            FileUtils.set_contents(pgp_send_stale_path, "stale pgp send plaintext\n");

            Dino.FileManager.cleanup_plaintext_lease_root_for_tests(root);

            fail_if(File.new_for_path(stale_path).query_exists(), "stale plaintext file must be removed");
            fail_if(File.new_for_path(lease_dir).query_exists(), "stale plaintext lease directory must be removed");
            fail_if(File.new_for_path(purpose_dir).query_exists(), "stale plaintext purpose directory must be removed");
            fail_if(File.new_for_path(pgp_send_stale_path).query_exists(), "stale PGP send plaintext file must be removed");
            fail_if(File.new_for_path(pgp_send_lease_dir).query_exists(), "stale PGP send lease directory must be removed");
            fail_if(File.new_for_path(pgp_send_purpose_dir).query_exists(), "stale PGP send purpose directory must be removed");
            fail_if(root_exists_and_is_not_empty(root), "plaintext lease root must be removed or left empty");
        } catch (Error e) {
            fail_if_reached(@"Plaintext lease cleanup test failed: $(e.message)");
        } finally {
            cleanup_test_dir(temp_dir);
        }
    }

    void test_plaintext_lease_cleanup_missing_root_is_noop() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string root = Path.build_filename(temp_dir, "dinox", "temp_plaintext");

        Dino.FileManager.cleanup_plaintext_lease_root_for_tests(root);

        fail_if(File.new_for_path(root).query_exists(), "missing plaintext lease root must not be created");
        cleanup_test_dir(temp_dir);
    }

    void test_plaintext_lease_cleanup_rejects_unexpected_root() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-unexpected-" + Uuid.string_random());
        string root = Path.build_filename(temp_dir, "dinox", "temp_plaintext");
        string lease_dir = Path.build_filename(root, "open", Uuid.string_random());
        string stale_path = Path.build_filename(lease_dir, "report.txt");

        try {
            DirUtils.create_with_parents(lease_dir, 0700);
            FileUtils.set_contents(stale_path, "must stay\n");

            Dino.FileManager.cleanup_plaintext_lease_root_for_tests(root);

            fail_if(!File.new_for_path(stale_path).query_exists(),
                "cleanup helper must reject roots outside the DinoX test pattern");
        } catch (Error e) {
            fail_if_reached(@"Plaintext lease unexpected-root test failed: $(e.message)");
        } finally {
            FileUtils.remove(stale_path);
            DirUtils.remove(lease_dir);
            cleanup_test_dir(temp_dir);
        }
    }

    void test_plaintext_lease_output_file_is_adoptable() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_root = Path.build_filename(temp_dir, "dinox", "temp_plaintext");
        string? lease_dir = null;
        string? output_path = null;
        Dino.PlaintextFileLeaseTarget? target = null;
        InputStream? stream = null;

        try {
            target = Dino.FileManager.create_plaintext_file_lease_target_for_tests("pgp-receive", lease_root);
            File output_file = ((!) target).file;
            lease_dir = ((!) target).directory;
            output_path = output_file.get_path();
            fail_if(output_path == null || ((!) output_path) == "",
                "plaintext lease output file must be a local path");
            fail_if(lease_dir == null || ((!) lease_dir) == "",
                "plaintext lease output target must expose its test lease directory");
            File? output_parent = output_file.get_parent();
            fail_if(output_parent == null || ((!) output_parent).get_path() != (!) lease_dir,
                "plaintext lease output file must be directly inside its lease directory");
            fail_if(Path.get_dirname((!) lease_dir) != Path.build_filename(lease_root, "pgp-receive"),
                "plaintext lease output file must use the sanitized purpose directory");
            fail_if(output_file.query_exists(),
                "plaintext lease output helper must reserve a path without creating plaintext");

            FileUtils.set_contents((!) output_path, "verified plaintext\n");
            var meta = new Dino.VerifiedPlaintextMeta() {
                file_name = "verified.txt",
                mime_type = "text/plain"
            };
            stream = ((!) target).open_input_stream(meta);
            target = null;

            Dino.VerifiedPlaintextMetaCarrier? carrier = stream as Dino.VerifiedPlaintextMetaCarrier;
            fail_if(carrier == null, "adopted plaintext lease output stream must expose verified metadata");
            Dino.VerifiedPlaintextMeta? carried_meta = ((!) carrier).get_verified_plaintext_meta();
            fail_if(carried_meta == null, "adopted plaintext lease output stream must carry verified metadata");
            fail_if_not_eq_str((!) ((!) carried_meta).file_name, "verified.txt",
                "adopted plaintext lease output stream must preserve filename metadata");

            uint8[] buffer = new uint8[32];
            ssize_t read_bytes = ((!) stream).read(buffer);
            fail_if(read_bytes <= 0, "adopted plaintext lease output stream must read the written file");

            ((!) stream).close();
            stream = null;

            fail_if(FileUtils.test((!) output_path, FileTest.EXISTS),
                "closing adopted plaintext lease output stream must remove the file");
            fail_if(FileUtils.test((!) lease_dir, FileTest.EXISTS),
                "closing adopted plaintext lease output stream must remove the lease directory");
        } catch (Error e) {
            fail_if_reached(@"Plaintext lease output file test failed: $(e.message)");
        } finally {
            if (target != null) {
                ((!) target).discard();
            }
            if (stream != null) {
                try { ((!) stream).close(); } catch (Error e) {}
            }
            if (output_path != null) FileUtils.remove((!) output_path);
            if (lease_dir != null) DirUtils.remove((!) lease_dir);
            Dino.FileManager.cleanup_plaintext_lease_root_for_tests(lease_root);
            cleanup_test_dir(temp_dir);
        }
    }

    void test_plaintext_file_lease_target_discard_removes_file_and_directory() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_root = Path.build_filename(temp_dir, "dinox", "temp_plaintext");
        string? lease_dir = null;
        string? output_path = null;
        Dino.PlaintextFileLeaseTarget? target = null;

        try {
            custom_delete_invoked = false;
            target = Dino.FileManager.create_plaintext_file_lease_target_for_tests("pgp-receive", lease_root, delete_with_marker);
            File output_file = ((!) target).file;
            lease_dir = ((!) target).directory;
            output_path = output_file.get_path();
            fail_if(output_path == null || ((!) output_path) == "",
                "plaintext lease target must reserve a local output path");
            fail_if(lease_dir == null || ((!) lease_dir) == "",
                "plaintext lease target must own a lease directory");

            FileUtils.set_contents((!) output_path, "temporary plaintext\n");
            ((!) target).discard();
            target = null;

            fail_if(!custom_delete_invoked, "discard() must use the target delete function");
            fail_if(FileUtils.test((!) output_path, FileTest.EXISTS),
                "discard() must remove the leased plaintext file");
            fail_if(FileUtils.test((!) lease_dir, FileTest.EXISTS),
                "discard() must remove the lease directory");
        } catch (Error e) {
            fail_if_reached(@"Plaintext lease target discard test failed: $(e.message)");
        } finally {
            if (target != null) {
                ((!) target).discard();
            }
            custom_delete_invoked = false;
            if (output_path != null) FileUtils.remove((!) output_path);
            if (lease_dir != null) DirUtils.remove((!) lease_dir);
            Dino.FileManager.cleanup_plaintext_lease_root_for_tests(lease_root);
            cleanup_test_dir(temp_dir);
        }
    }

    void test_plaintext_file_lease_release_removes_file_and_directory_idempotently() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_dir = Path.build_filename(temp_dir, "lease-" + Uuid.string_random());
        string plaintext_path = Path.build_filename(lease_dir, "report.txt");

        try {
            DirUtils.create_with_parents(lease_dir, 0700);
            FileUtils.set_contents(plaintext_path, "temporary plaintext\n");

            File plaintext_file = File.new_for_path(plaintext_path);
            var lease = new Dino.PlaintextFileLease(plaintext_file, lease_dir);

            lease.release();
            fail_if(plaintext_file.query_exists(), "release() must remove the leased plaintext file");
            fail_if(File.new_for_path(lease_dir).query_exists(), "release() must remove the unique lease directory");

            lease.release();
            fail_if(plaintext_file.query_exists(), "second release() must not recreate or keep the plaintext file");
            fail_if(File.new_for_path(lease_dir).query_exists(), "second release() must be a no-op for the removed lease directory");
        } catch (Error e) {
            fail_if_reached(@"PlaintextFileLease idempotent release test failed: $(e.message)");
        } finally {
            FileUtils.remove(plaintext_path);
            DirUtils.remove(lease_dir);
            DirUtils.remove(temp_dir);
        }
    }

    void test_plaintext_file_lease_release_retries_directory_cleanup() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_dir = Path.build_filename(temp_dir, "lease-" + Uuid.string_random());
        string plaintext_path = Path.build_filename(lease_dir, "report.txt");
        string sibling_path = Path.build_filename(lease_dir, "sibling.txt");

        try {
            DirUtils.create_with_parents(lease_dir, 0700);
            FileUtils.set_contents(plaintext_path, "temporary plaintext\n");
            FileUtils.set_contents(sibling_path, "blocks directory removal\n");

            File plaintext_file = File.new_for_path(plaintext_path);
            File lease_directory = File.new_for_path(lease_dir);
            File sibling_file = File.new_for_path(sibling_path);
            var lease = new Dino.PlaintextFileLease(plaintext_file, lease_dir);

            lease.release();
            fail_if(plaintext_file.query_exists(), "release() must remove the leased file before retrying directory cleanup");
            fail_if(!lease_directory.query_exists(), "non-empty lease directory must remain after the first cleanup attempt");

            sibling_file.delete(null);
            fail_if(!wait_for_path_absent(lease_dir, 6000), "retry must remove the lease directory after the sibling is gone");
        } catch (Error e) {
            fail_if_reached(@"PlaintextFileLease retry release test failed: $(e.message)");
        } finally {
            FileUtils.remove(plaintext_path);
            FileUtils.remove(sibling_path);
            DirUtils.remove(lease_dir);
            DirUtils.remove(temp_dir);
        }
    }

    void test_create_plaintext_file_lease_rejects_incomplete_transfer_sync() {
        var loop = new MainLoop();
        test_create_plaintext_file_lease_rejects_incomplete_transfer.begin((obj, res) => {
            test_create_plaintext_file_lease_rejects_incomplete_transfer.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_create_plaintext_file_lease_rejects_incomplete_transfer() {
        var manager = Dino.FileManager.create_for_tests();
        Dino.Entities.FileTransfer.State[] states = {
            Dino.Entities.FileTransfer.State.NOT_STARTED,
            Dino.Entities.FileTransfer.State.IN_PROGRESS,
            Dino.Entities.FileTransfer.State.FAILED
        };
        string[] purposes = {
            "open",
            "image-preview",
            "audio-playback",
            "video-preview",
            "video-playback"
        };

        foreach (Dino.Entities.FileTransfer.State state in states) {
            foreach (string purpose in purposes) {
                var file_transfer = create_incomplete_received_transfer_for_plaintext_release_test(state);

                bool denied = false;
                try {
                    Dino.PlaintextFileLease lease = yield manager.create_plaintext_file_lease(file_transfer, purpose);
                    lease.release();
                } catch (IOError.PERMISSION_DENIED e) {
                    denied = true;
                } catch (Error e) {
                    fail_if_reached(@"Incomplete transfer plaintext lease guard for $(purpose) raised unexpected error: $(e.message)");
                }

                fail_if(!denied, @"Incomplete transfers must not create a plaintext $(purpose) lease");
            }
        }
    }

    void test_plaintext_release_guard_covers_ui_purposes_and_export_sync() {
        var loop = new MainLoop();
        test_plaintext_release_guard_covers_ui_purposes_and_export.begin((obj, res) => {
            test_plaintext_release_guard_covers_ui_purposes_and_export.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_plaintext_release_guard_covers_ui_purposes_and_export() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string storage_name = "gate4-" + Uuid.string_random() + ".enc";
        string storage_path = Path.build_filename(Dino.FileManager.get_storage_dir(), storage_name);
        string target_path = Path.build_filename(temp_dir, "exported.txt");
        Dino.Database? db = null;

        string[] purposes = {
            "open",
            "image-preview",
            "audio-playback",
            "video-preview",
            "video-playback"
        };
        Dino.Entities.FileTransfer.Phase[] blocked_phases = {
            Dino.Entities.FileTransfer.Phase.NONE,
            Dino.Entities.FileTransfer.Phase.PREPARING,
            Dino.Entities.FileTransfer.Phase.ENCRYPTING,
            Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
            Dino.Entities.FileTransfer.Phase.UPLOADING,
            Dino.Entities.FileTransfer.Phase.ANNOUNCING,
            Dino.Entities.FileTransfer.Phase.DOWNLOADING,
            Dino.Entities.FileTransfer.Phase.DECRYPTING,
            Dino.Entities.FileTransfer.Phase.VERIFYING,
            Dino.Entities.FileTransfer.Phase.STORING,
            Dino.Entities.FileTransfer.Phase.PREVIEWING,
            Dino.Entities.FileTransfer.Phase.FAILED
        };

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            DirUtils.create_with_parents(Dino.FileManager.get_storage_dir(), 0700);

            db = new Dino.Database(db_path, "gate4-plaintext-release-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            var file_encryption = new Dino.Security.FileEncryption("gate4-plaintext-release-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            uint8[] plaintext = "gate4 verified plaintext\n".data;
            yield write_encrypted_export_source(file_encryption, File.new_for_path(storage_path), plaintext);

            foreach (Dino.Entities.FileTransfer.Phase phase in blocked_phases) {
                var file_transfer = create_stored_received_transfer_for_plaintext_release_test(
                    storage_name, plaintext.length, phase);

                foreach (string purpose in purposes) {
                    bool denied = false;
                    try {
                        Dino.PlaintextFileLease lease = yield ((!) manager).create_plaintext_file_lease(file_transfer, purpose);
                        lease.release();
                    } catch (IOError.PERMISSION_DENIED e) {
                        denied = true;
                    } catch (Error e) {
                        fail_if_reached(@"Gate 4 plaintext lease guard for $(purpose)/$(phase.to_string()) raised unexpected error: $(e.message)");
                    }
                    fail_if(!denied, @"Gate 4 must block $(purpose) plaintext leases while transfer phase is $(phase.to_string())");
                }

                FileUtils.set_contents(target_path, "existing target\n");
                bool export_denied = false;
                try {
                    yield ((!) manager).export_plaintext_file(file_transfer, File.new_for_path(target_path));
                } catch (IOError.PERMISSION_DENIED e) {
                    export_denied = true;
                } catch (Error e) {
                    fail_if_reached(@"Gate 4 export guard for $(phase.to_string()) raised unexpected error: $(e.message)");
                }

                string target_contents;
                FileUtils.get_contents(target_path, out target_contents);
                fail_if(!export_denied, @"Gate 4 must block export while transfer phase is $(phase.to_string())");
                fail_if_not_eq_str(target_contents, "existing target\n",
                    "blocked Gate 4 export must leave the selected target untouched");
                fail_if(count_export_pending_files(temp_dir) != 0,
                    "blocked Gate 4 export must not create a pending target file");
            }

            var complete_transfer = create_stored_received_transfer_for_plaintext_release_test(
                storage_name, plaintext.length, Dino.Entities.FileTransfer.Phase.COMPLETE);
            foreach (string purpose in purposes) {
                Dino.PlaintextFileLease lease = yield ((!) manager).create_plaintext_file_lease(complete_transfer, purpose);
                try {
                    string lease_contents;
                    FileUtils.get_contents(lease.file.get_path(), out lease_contents);
                    fail_if_not_eq_str(lease_contents, "gate4 verified plaintext\n",
                        @"complete transfers must decrypt plaintext for $(purpose)");
                } finally {
                    lease.release();
                }
            }

            FileUtils.set_contents(target_path, "old target\n");
            yield ((!) manager).export_plaintext_file(complete_transfer, File.new_for_path(target_path));
            string exported_contents;
            FileUtils.get_contents(target_path, out exported_contents);
            fail_if_not_eq_str(exported_contents, "gate4 verified plaintext\n",
                "complete transfers must export verified plaintext");
            fail_if(count_export_pending_files(temp_dir) != 0,
                "successful Gate 4 export must not leave pending target files");
        } catch (Error e) {
            fail_if_reached(@"Gate 4 plaintext release matrix test failed: $(e.message)");
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(storage_path);
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_verified_plaintext_input_stream_carries_meta_and_releases_lease() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_dir = Path.build_filename(temp_dir, "lease-" + Uuid.string_random());
        string plaintext_path = Path.build_filename(lease_dir, "report.txt");
        InputStream? stream = null;

        try {
            DirUtils.create_with_parents(lease_dir, 0700);
            FileUtils.set_contents(plaintext_path, "verified plaintext\n");

            var meta = new Dino.VerifiedPlaintextMeta() {
                file_name = "report.txt",
                mime_type = "text/plain"
            };
            stream = Dino.FileManager.create_plaintext_file_lease_input_stream(File.new_for_path(plaintext_path), lease_dir, meta);

            Dino.VerifiedPlaintextMetaCarrier? carrier = stream as Dino.VerifiedPlaintextMetaCarrier;
            fail_if(carrier == null, "verified plaintext stream must expose metadata through the carrier interface");
            Dino.VerifiedPlaintextMeta? carried_meta = ((!) carrier).get_verified_plaintext_meta();
            fail_if(carried_meta == null, "verified plaintext stream must carry metadata");
            fail_if_not_eq_str((!) ((!) carried_meta).file_name, "report.txt",
                "verified plaintext stream must preserve the filename metadata");
            fail_if_not_eq_str((!) ((!) carried_meta).mime_type, "text/plain",
                "verified plaintext stream must preserve the MIME metadata");

            uint8[] buffer = new uint8[32];
            ssize_t read_bytes = ((!) stream).read(buffer);
            fail_if(read_bytes <= 0, "verified plaintext stream must read from the leased file");

            ((!) stream).close();
            fail_if(FileUtils.test(plaintext_path, FileTest.EXISTS),
                "verified plaintext stream close() must release the leased file");
            fail_if(FileUtils.test(lease_dir, FileTest.EXISTS),
                "verified plaintext stream close() must remove the lease directory");

            ((!) stream).close();
            stream = null;
        } catch (Error e) {
            fail_if_reached(@"Verified plaintext input stream test failed: $(e.message)");
        } finally {
            if (stream != null) {
                try { ((!) stream).close(); } catch (Error e) {}
            }
            FileUtils.remove(plaintext_path);
            DirUtils.remove(lease_dir);
            DirUtils.remove(temp_dir);
        }
    }

    void test_verified_plaintext_input_stream_close_async_releases_lease_idempotently() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_dir = Path.build_filename(temp_dir, "lease-" + Uuid.string_random());
        string plaintext_path = Path.build_filename(lease_dir, "report.txt");
        InputStream? stream = null;

        try {
            DirUtils.create_with_parents(lease_dir, 0700);
            FileUtils.set_contents(plaintext_path, "verified plaintext\n");
            stream = Dino.FileManager.create_plaintext_file_lease_input_stream(File.new_for_path(plaintext_path), lease_dir);

            bool first_close = close_stream_async((!) stream);
            fail_if(!first_close, "verified plaintext stream close_async() must report successful close");
            fail_if(FileUtils.test(plaintext_path, FileTest.EXISTS),
                "verified plaintext stream close_async() must release the leased file");
            fail_if(FileUtils.test(lease_dir, FileTest.EXISTS),
                "verified plaintext stream close_async() must remove the lease directory");

            bool second_close = close_stream_async((!) stream);
            fail_if(!second_close, "verified plaintext stream close_async() must be idempotent");
            stream = null;
        } catch (Error e) {
            fail_if_reached(@"Verified plaintext input stream async cleanup test failed: $(e.message)");
        } finally {
            if (stream != null) {
                try { ((!) stream).close(); } catch (Error e) {}
            }
            FileUtils.remove(plaintext_path);
            DirUtils.remove(lease_dir);
            DirUtils.remove(temp_dir);
        }
    }

    void test_verified_plaintext_input_stream_rejects_non_local_plaintext_file() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_dir = Path.build_filename(temp_dir, "lease-" + Uuid.string_random());

        try {
            DirUtils.create_with_parents(lease_dir, 0700);

            expect_plaintext_lease_adoption_rejected(File.new_for_uri("https://example.invalid/report.txt"), lease_dir,
                "verified plaintext stream must reject a non-local plaintext URI");
            fail_if(!FileUtils.test(lease_dir, FileTest.IS_DIR),
                "rejected non-local plaintext URI must not remove the supplied lease directory");
        } finally {
            DirUtils.remove(lease_dir);
            DirUtils.remove(temp_dir);
        }
    }

    void test_verified_plaintext_input_stream_rejects_relative_plaintext_file() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_dir = Path.build_filename(temp_dir, "lease-" + Uuid.string_random());
        string relative_path = "relative-report-" + Uuid.string_random() + ".txt";

        try {
            DirUtils.create_with_parents(lease_dir, 0700);

            expect_plaintext_lease_adoption_rejected(File.new_for_path(relative_path), lease_dir,
                "verified plaintext stream must reject a relative plaintext file path");
            fail_if(!FileUtils.test(lease_dir, FileTest.IS_DIR),
                "rejected relative plaintext file must not remove the supplied lease directory");
        } finally {
            DirUtils.remove(lease_dir);
            DirUtils.remove(temp_dir);
        }
    }

    void test_verified_plaintext_input_stream_rejects_invalid_lease_directory_path() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_dir = Path.build_filename(temp_dir, "lease-" + Uuid.string_random());
        string plaintext_path = Path.build_filename(lease_dir, "report.txt");
        File plaintext_file = File.new_for_path(plaintext_path);

        try {
            DirUtils.create_with_parents(lease_dir, 0700);
            FileUtils.set_contents(plaintext_path, "verified plaintext\n");

            expect_plaintext_lease_adoption_rejected(plaintext_file, null,
                "verified plaintext stream must reject a null lease directory");
            expect_plaintext_lease_adoption_rejected(plaintext_file, "",
                "verified plaintext stream must reject an empty lease directory");
            expect_plaintext_lease_adoption_rejected(plaintext_file, "relative-lease-" + Uuid.string_random(),
                "verified plaintext stream must reject a relative lease directory");

            assert_file_contents(plaintext_path, "verified plaintext\n",
                "rejected invalid lease directory must not delete or rewrite the plaintext file");
            fail_if(!FileUtils.test(lease_dir, FileTest.IS_DIR),
                "rejected invalid lease directory must not remove the supplied lease directory");
        } catch (Error e) {
            fail_if_reached(@"Verified plaintext invalid lease directory rejection test failed: $(e.message)");
        } finally {
            FileUtils.remove(plaintext_path);
            DirUtils.remove(lease_dir);
            DirUtils.remove(temp_dir);
        }
    }

    void test_verified_plaintext_input_stream_rejects_file_outside_lease_directory() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_dir = Path.build_filename(temp_dir, "lease-" + Uuid.string_random());
        string outside_path = Path.build_filename(temp_dir, "outside.txt");

        try {
            DirUtils.create_with_parents(lease_dir, 0700);
            FileUtils.set_contents(outside_path, "outside plaintext\n");

            expect_plaintext_lease_adoption_rejected(File.new_for_path(outside_path), lease_dir,
                "verified plaintext stream must reject a file outside the adopted lease directory");
            fail_if(!FileUtils.test(outside_path, FileTest.EXISTS),
                "rejected lease adoption must not delete the outside file");
            fail_if(!FileUtils.test(lease_dir, FileTest.IS_DIR),
                "rejected lease adoption must not delete the supplied lease directory");
        } catch (Error e) {
            fail_if_reached(@"Verified plaintext input stream rejection test failed: $(e.message)");
        } finally {
            FileUtils.remove(outside_path);
            DirUtils.remove(lease_dir);
            DirUtils.remove(temp_dir);
        }
    }

    void test_verified_plaintext_input_stream_rejects_symlink_plaintext_file() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_dir = Path.build_filename(temp_dir, "lease-" + Uuid.string_random());
        string user_plaintext_path = Path.build_filename(temp_dir, "user-report.txt");
        string plaintext_symlink_path = Path.build_filename(lease_dir, "report.txt");

        try {
            DirUtils.create_with_parents(lease_dir, 0700);
            FileUtils.set_contents(user_plaintext_path, "user plaintext\n");
            if (!create_symlink_or_skip(user_plaintext_path, plaintext_symlink_path)) return;

            expect_plaintext_lease_adoption_rejected(File.new_for_path(plaintext_symlink_path), lease_dir,
                "verified plaintext stream must reject a symlink plaintext file");
            fail_if(!FileUtils.test(user_plaintext_path, FileTest.EXISTS),
                "rejected symlink plaintext file must not delete the symlink target");
            fail_if(!FileUtils.test(plaintext_symlink_path, FileTest.IS_SYMLINK),
                "rejected symlink plaintext file must leave the symlink for caller-owned cleanup");
        } catch (Error e) {
            fail_if_reached(@"Verified plaintext symlink file rejection test failed: $(e.message)");
        } finally {
            FileUtils.remove(plaintext_symlink_path);
            FileUtils.remove(user_plaintext_path);
            DirUtils.remove(lease_dir);
            DirUtils.remove(temp_dir);
        }
    }

    void test_verified_plaintext_input_stream_rejects_symlink_lease_directory() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string real_lease_dir = Path.build_filename(temp_dir, "user-owned-dir");
        string lease_symlink_path = Path.build_filename(temp_dir, "lease-link");
        string user_plaintext_path = Path.build_filename(real_lease_dir, "report.txt");
        string plaintext_path_through_symlink = Path.build_filename(lease_symlink_path, "report.txt");

        try {
            DirUtils.create_with_parents(real_lease_dir, 0700);
            FileUtils.set_contents(user_plaintext_path, "user plaintext\n");
            if (!create_symlink_or_skip(real_lease_dir, lease_symlink_path)) return;

            expect_plaintext_lease_adoption_rejected(File.new_for_path(plaintext_path_through_symlink), lease_symlink_path,
                "verified plaintext stream must reject a symlink lease directory");
            fail_if(!FileUtils.test(user_plaintext_path, FileTest.EXISTS),
                "rejected symlink lease directory must not delete the target plaintext file");
            fail_if(!FileUtils.test(lease_symlink_path, FileTest.IS_SYMLINK),
                "rejected symlink lease directory must leave the symlink for caller-owned cleanup");
        } catch (Error e) {
            fail_if_reached(@"Verified plaintext symlink directory rejection test failed: $(e.message)");
        } finally {
            FileUtils.remove(lease_symlink_path);
            FileUtils.remove(user_plaintext_path);
            DirUtils.remove(real_lease_dir);
            DirUtils.remove(temp_dir);
        }
    }

    void test_verified_plaintext_input_stream_rejects_non_directory_lease_path() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_file_path = Path.build_filename(temp_dir, "lease-file");
        string plaintext_path = Path.build_filename(lease_file_path, "report.txt");

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            FileUtils.set_contents(lease_file_path, "not a directory\n");

            expect_plaintext_lease_adoption_rejected(File.new_for_path(plaintext_path), lease_file_path,
                "verified plaintext stream must reject a non-directory lease path");
            assert_file_contents(lease_file_path, "not a directory\n",
                "rejected non-directory lease path must not delete or rewrite the caller-owned file");
        } catch (Error e) {
            fail_if_reached(@"Verified plaintext non-directory lease rejection test failed: $(e.message)");
        } finally {
            FileUtils.remove(lease_file_path);
            DirUtils.remove(temp_dir);
        }
    }

    void test_verified_plaintext_input_stream_rejects_non_regular_plaintext_path() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_dir = Path.build_filename(temp_dir, "lease-" + Uuid.string_random());
        string plaintext_dir_path = Path.build_filename(lease_dir, "report.txt");
        string sentinel_path = Path.build_filename(plaintext_dir_path, "keep.txt");

        try {
            DirUtils.create_with_parents(plaintext_dir_path, 0700);
            FileUtils.set_contents(sentinel_path, "caller-owned directory content\n");

            expect_plaintext_lease_adoption_rejected(File.new_for_path(plaintext_dir_path), lease_dir,
                "verified plaintext stream must reject a non-regular plaintext path");
            assert_file_contents(sentinel_path, "caller-owned directory content\n",
                "rejected non-regular plaintext path must not delete directory contents");
            fail_if(!FileUtils.test(plaintext_dir_path, FileTest.IS_DIR),
                "rejected non-regular plaintext path must not delete the caller-owned directory");
            fail_if(!FileUtils.test(lease_dir, FileTest.IS_DIR),
                "rejected non-regular plaintext path must not delete the lease directory");
        } catch (Error e) {
            fail_if_reached(@"Verified plaintext non-regular file rejection test failed: $(e.message)");
        } finally {
            FileUtils.remove(sentinel_path);
            DirUtils.remove(plaintext_dir_path);
            DirUtils.remove(lease_dir);
            DirUtils.remove(temp_dir);
        }
    }

    void test_verified_plaintext_input_stream_uses_custom_delete_func() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string lease_dir = Path.build_filename(temp_dir, "lease-" + Uuid.string_random());
        string plaintext_path = Path.build_filename(lease_dir, "report.txt");
        InputStream? stream = null;

        try {
            custom_delete_invoked = false;
            DirUtils.create_with_parents(lease_dir, 0700);
            FileUtils.set_contents(plaintext_path, "verified plaintext\n");

            stream = Dino.FileManager.create_plaintext_file_lease_input_stream(
                    File.new_for_path(plaintext_path), lease_dir, null, delete_with_marker);
            ((!) stream).close();
            stream = null;

            fail_if(!custom_delete_invoked, "verified plaintext stream must use the caller-provided delete function");
            fail_if(FileUtils.test(plaintext_path, FileTest.EXISTS),
                "caller-provided delete function must remove the leased file");
            fail_if(FileUtils.test(lease_dir, FileTest.EXISTS),
                "lease release must remove the directory after custom file deletion");
        } catch (Error e) {
            fail_if_reached(@"Verified plaintext input stream custom delete test failed: $(e.message)");
        } finally {
            custom_delete_invoked = false;
            if (stream != null) {
                try { ((!) stream).close(); } catch (Error e) {}
            }
            FileUtils.remove(plaintext_path);
            DirUtils.remove(lease_dir);
            DirUtils.remove(temp_dir);
        }
    }

    private static void delete_with_marker(File file) throws Error {
        custom_delete_invoked = true;
        file.delete(null);
    }

    private static void preserve_rejected_plaintext_file(File file) throws Error {
    }

    private void expect_plaintext_lease_adoption_rejected(File plaintext_file, string? lease_dir, string reason) {
        InputStream? stream = null;
        bool rejected = false;

        try {
            stream = Dino.FileManager.create_plaintext_file_lease_input_stream(
                    plaintext_file, lease_dir, null, preserve_rejected_plaintext_file);
        } catch (IOError.PERMISSION_DENIED e) {
            rejected = true;
        } catch (Error e) {
            fail_if_reached("%s: unexpected error: %s".printf(reason, e.message));
        } finally {
            if (stream != null) {
                try { ((!) stream).close(); } catch (Error e) {}
            }
        }

        fail_if(!rejected, reason);
    }

    private bool create_symlink_or_skip(string target_path, string symlink_path) {
#if WINDOWS
        GLib.Test.skip("Symbolic link creation unavailable on Windows");
        return false;
#else
        if (FileUtils.symlink(target_path, symlink_path) == 0) return true;

        int symlink_errno = errno;
        GLib.Test.skip("Symbolic link creation unavailable: %s".printf(FileUtils.error_from_errno(symlink_errno).to_string()));
        return false;
#endif
    }

    private void assert_file_contents(string path, string expected_contents, string reason) {
        string contents;
        try {
            FileUtils.get_contents(path, out contents);
            fail_if_not_eq_str(contents, expected_contents, reason);
        } catch (Error e) {
            fail_if_reached("%s: %s".printf(reason, e.message));
        }
    }

    private bool close_stream_async(InputStream stream) throws Error {
        Error? close_error = null;
        bool close_result = false;
        var loop = new MainLoop();

        stream.close_async.begin(Priority.DEFAULT, null, (obj, res) => {
            try {
                close_result = stream.close_async.end(res);
            } catch (Error e) {
                close_error = e;
            }
            loop.quit();
        });
        loop.run();

        if (close_error != null) throw (!) close_error;
        return close_result;
    }

    private bool root_exists_and_is_not_empty(string root) throws Error {
        File root_file = File.new_for_path(root);
        if (!root_file.query_exists()) return false;

        FileEnumerator enumerator = root_file.enumerate_children("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        bool has_child = enumerator.next_file() != null;
        enumerator.close();
        return has_child;
    }

    private bool wait_for_path_absent(string path, uint timeout_ms) {
        if (!FileUtils.test(path, FileTest.EXISTS)) return true;

        var loop = new MainLoop();
        bool absent = false;
        uint poll_source = 0;
        uint timeout_source = 0;

        poll_source = Timeout.add(25, () => {
            if (!FileUtils.test(path, FileTest.EXISTS)) {
                absent = true;
                poll_source = 0;
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });

        timeout_source = Timeout.add(timeout_ms, () => {
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        return absent || !FileUtils.test(path, FileTest.EXISTS);
    }

    private bool wait_for_transfer_phase(Dino.Entities.FileTransfer file_transfer, Dino.Entities.FileTransfer.Phase expected_phase, uint timeout_ms) {
        if (file_transfer.phase == expected_phase) return true;

        var loop = new MainLoop();
        uint poll_source = 0;
        uint timeout_source = 0;

        poll_source = Timeout.add(25, () => {
            if (file_transfer.phase == expected_phase || file_transfer.phase == Dino.Entities.FileTransfer.Phase.FAILED) {
                poll_source = 0;
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });

        timeout_source = Timeout.add(timeout_ms, () => {
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        return file_transfer.phase == expected_phase;
    }

    private bool wait_for_ibb_connection(FileManagerJingleTestXmppStream stream, string sid, uint timeout_ms) {
        var ibb_flag = stream.get_flag(Xmpp.Xep.InBandBytestreams.Flag.IDENTITY);
        if (ibb_flag != null && ((!) ibb_flag).get_connection(sid) != null) return true;

        var loop = new MainLoop();
        bool available = false;
        uint poll_source = 0;
        uint timeout_source = 0;

        poll_source = Timeout.add(25, () => {
            var flag = stream.get_flag(Xmpp.Xep.InBandBytestreams.Flag.IDENTITY);
            available = flag != null && ((!) flag).get_connection(sid) != null;
            if (available) {
                poll_source = 0;
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });

        timeout_source = Timeout.add(timeout_ms, () => {
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        return available;
    }

    private void seed_trusted_roster_contact(Dino.Database db, Dino.Entities.Account account, Xmpp.Jid jid) {
        db.roster.upsert()
            .value(db.roster.account_id, account.id, true)
            .value(db.roster.jid, jid.bare_jid.to_string(), true)
            .value(db.roster.handle, "Bob")
            .value(db.roster.subscription, Xmpp.Roster.Item.SUBSCRIPTION_BOTH)
            .perform();
    }

    private void attach_service_discovery_modules_for_tests(Dino.StreamInteractor stream_interactor, Dino.Entities.Account account, FileManagerJingleTestXmppStream stream) {
        var bind_flag = new Xmpp.Bind.Flag();
        bind_flag.my_jid = account.full_jid;
        bind_flag.finished = true;
        stream.add_flag(bind_flag);

        var iq = stream_interactor.module_manager.get_module<Xmpp.Iq.Module>(account, Xmpp.Iq.Module.IDENTITY);
        fail_if(iq == null, "test setup must provide the IQ module");
        stream.add_module((!) iq);
        ((!) iq).attach(stream);

        var service_discovery = stream_interactor.module_manager.get_module<Xmpp.Xep.ServiceDiscovery.Module>(account, Xmpp.Xep.ServiceDiscovery.Module.IDENTITY);
        fail_if(service_discovery == null, "test setup must provide the service-discovery module");
        stream.add_module((!) service_discovery);
        ((!) service_discovery).attach(stream);
    }

    private void attach_jingle_ibb_modules_for_tests(Dino.StreamInteractor stream_interactor, Dino.Entities.Account account, FileManagerJingleTestXmppStream stream) {
        var bind_flag = new Xmpp.Bind.Flag();
        bind_flag.my_jid = account.full_jid;
        bind_flag.finished = true;
        stream.add_flag(bind_flag);

        var iq = stream_interactor.module_manager.get_module<Xmpp.Iq.Module>(account, Xmpp.Iq.Module.IDENTITY);
        fail_if(iq == null, "test setup must provide the IQ module");
        stream.add_module((!) iq);
        ((!) iq).attach(stream);

        var service_discovery = stream_interactor.module_manager.get_module<Xmpp.Xep.ServiceDiscovery.Module>(account, Xmpp.Xep.ServiceDiscovery.Module.IDENTITY);
        fail_if(service_discovery == null, "test setup must provide the service-discovery module");
        stream.add_module((!) service_discovery);
        ((!) service_discovery).attach(stream);

        var jingle = stream_interactor.module_manager.get_module<Xmpp.Xep.Jingle.Module>(account, Xmpp.Xep.Jingle.Module.IDENTITY);
        fail_if(jingle == null, "test setup must provide the Jingle module");
        stream.add_module((!) jingle);
        ((!) jingle).attach(stream);

        var file_transfer = stream_interactor.module_manager.get_module<Xmpp.Xep.JingleFileTransfer.Module>(account, Xmpp.Xep.JingleFileTransfer.Module.IDENTITY);
        fail_if(file_transfer == null, "test setup must provide the Jingle file-transfer module");
        stream.add_module((!) file_transfer);
        ((!) file_transfer).attach(stream);

        var in_band_bytestreams = stream_interactor.module_manager.get_module<Xmpp.Xep.InBandBytestreams.Module>(account, Xmpp.Xep.InBandBytestreams.Module.IDENTITY);
        fail_if(in_band_bytestreams == null, "test setup must provide the IBB module");
        stream.add_module((!) in_band_bytestreams);
        ((!) in_band_bytestreams).attach(stream);

        var jingle_ibb = stream_interactor.module_manager.get_module<Xmpp.Xep.JingleInBandBytestreams.Module>(account, Xmpp.Xep.JingleInBandBytestreams.Module.IDENTITY);
        fail_if(jingle_ibb == null, "test setup must provide the Jingle IBB module");
        stream.add_module((!) jingle_ibb);
        ((!) jingle_ibb).attach(stream);
    }

    private void attach_jingle_s5b_modules_for_tests(Dino.StreamInteractor stream_interactor, Dino.Entities.Account account, FileManagerJingleTestXmppStream stream) {
        var bind_flag = new Xmpp.Bind.Flag();
        bind_flag.my_jid = account.full_jid;
        bind_flag.finished = true;
        stream.add_flag(bind_flag);

        var socks5 = stream_interactor.module_manager.get_module<Xmpp.Xep.Socks5Bytestreams.Module>(account, Xmpp.Xep.Socks5Bytestreams.Module.IDENTITY);
        fail_if(socks5 == null, "test setup must provide the SOCKS5 bytestreams module");
        ((!) socks5).set_local_ip_address_handler(() => {
            var addresses = new ArrayList<string>();
            addresses.add("127.0.0.1");
            return addresses;
        });
        stream.add_module((!) socks5);
        stream.add_flag(new Xmpp.Xep.Socks5Bytestreams.Flag());

        var iq = stream_interactor.module_manager.get_module<Xmpp.Iq.Module>(account, Xmpp.Iq.Module.IDENTITY);
        fail_if(iq == null, "test setup must provide the IQ module");
        stream.add_module((!) iq);
        ((!) iq).attach(stream);

        var service_discovery = stream_interactor.module_manager.get_module<Xmpp.Xep.ServiceDiscovery.Module>(account, Xmpp.Xep.ServiceDiscovery.Module.IDENTITY);
        fail_if(service_discovery == null, "test setup must provide the service-discovery module");
        stream.add_module((!) service_discovery);
        ((!) service_discovery).attach(stream);

        var jingle = stream_interactor.module_manager.get_module<Xmpp.Xep.Jingle.Module>(account, Xmpp.Xep.Jingle.Module.IDENTITY);
        fail_if(jingle == null, "test setup must provide the Jingle module");
        stream.add_module((!) jingle);
        ((!) jingle).attach(stream);

        var file_transfer = stream_interactor.module_manager.get_module<Xmpp.Xep.JingleFileTransfer.Module>(account, Xmpp.Xep.JingleFileTransfer.Module.IDENTITY);
        fail_if(file_transfer == null, "test setup must provide the Jingle file-transfer module");
        stream.add_module((!) file_transfer);
        ((!) file_transfer).attach(stream);

        var jingle_s5b = stream_interactor.module_manager.get_module<Xmpp.Xep.JingleSocks5Bytestreams.Module>(account, Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY);
        fail_if(jingle_s5b == null, "test setup must provide the Jingle S5B module");
        stream.add_module((!) jingle_s5b);
        ((!) jingle_s5b).attach(stream);
    }

    private void attach_test_jet_security_for_tests(FileManagerJingleTestXmppStream stream) {
        var jet = new Xmpp.Xep.Jet.Module();
        stream.add_module(jet);
        jet.attach(stream);
        jet.register_envelop_encoding(new FileManagerTestJetEnvelope());
        jet.register_cipher(new FileManagerTestJetCipher());
    }

    private Dino.JingleFileEncryptionHelper? register_test_jingle_file_encryption_helper() {
        var registry = Dino.JingleFileHelperRegistry.instance;
        Dino.JingleFileEncryptionHelper? previous_helper = registry.get_encryption_helper(Dino.Entities.Encryption.OMEMO);
        registry.add_encryption_helper(
            Dino.Entities.Encryption.OMEMO,
            new FileManagerTestJingleFileEncryptionHelper());
        return previous_helper;
    }

    private void restore_test_jingle_file_encryption_helper(Dino.JingleFileEncryptionHelper? previous_helper) {
        var registry = Dino.JingleFileHelperRegistry.instance;
        if (previous_helper != null) {
            registry.add_encryption_helper(Dino.Entities.Encryption.OMEMO, (!) previous_helper);
        } else {
            registry.encryption_helpers.unset(Dino.Entities.Encryption.OMEMO);
        }
    }

    private void add_s5b_proxy(FileManagerJingleTestXmppStream stream, string host, Xmpp.Jid jid, int port) {
        var socks5_flag = stream.get_flag(Xmpp.Xep.Socks5Bytestreams.Flag.IDENTITY);
        fail_if(socks5_flag == null, "test setup must attach the SOCKS5 bytestreams flag");
        ((!) socks5_flag).proxies.add(new Xmpp.Xep.Socks5Bytestreams.Proxy(host, jid, port));
    }

    private StanzaNode build_incoming_jingle_ibb_iq(Xmpp.Jid peer, string sid, string file_name, int64 file_size) {
        StanzaNode transport = new StanzaNode.build("transport", Xmpp.Xep.JingleInBandBytestreams.Module.IDENTITY.ns)
            .add_self_xmlns()
            .put_attribute("sid", "incoming-ibb-session")
            .put_attribute("block-size", "4096");
        StanzaNode content = new StanzaNode.build("content", "urn:xmpp:jingle:1")
            .put_attribute("creator", "initiator")
            .put_attribute("name", "incoming-file")
            .put_attribute("senders", "initiator")
            .put_node(build_jingle_file_description(file_name, file_size.to_string()))
            .put_node(transport);
        StanzaNode jingle = new StanzaNode.build("jingle", "urn:xmpp:jingle:1")
            .add_self_xmlns()
            .put_attribute("action", "session-initiate")
            .put_attribute("initiator", peer.to_string())
            .put_attribute("sid", sid)
            .put_node(content);
        return new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", "libdino-incoming-jingle-ibb")
            .put_attribute("from", peer.to_string())
            .put_attribute("to", "alice@example.test/dinox")
            .put_node(jingle);
    }

    private StanzaNode build_incoming_jingle_s5b_iq(Xmpp.Jid peer, string sid, string content_name, string s5b_sid, string file_name, int64 file_size, StanzaNode? security = null) throws Error {
        var local = new Xmpp.Jid("alice@example.test/dinox");
        string dstaddr = Xmpp.Xep.JingleSocks5Bytestreams.calculate_dstaddr(s5b_sid, peer, local);
        StanzaNode transport = new StanzaNode.build("transport", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns)
            .add_self_xmlns()
            .put_attribute("mode", "tcp")
            .put_attribute("sid", s5b_sid)
            .put_attribute("dstaddr", dstaddr);
        StanzaNode content = new StanzaNode.build("content", "urn:xmpp:jingle:1")
            .put_attribute("creator", "initiator")
            .put_attribute("name", content_name)
            .put_attribute("senders", "initiator")
            .put_node(build_jingle_file_description(file_name, file_size.to_string()))
            .put_node(transport);
        if (security != null) {
            content.put_node((!) security);
        }
        StanzaNode jingle = new StanzaNode.build("jingle", "urn:xmpp:jingle:1")
            .add_self_xmlns()
            .put_attribute("action", "session-initiate")
            .put_attribute("initiator", peer.to_string())
            .put_attribute("sid", sid)
            .put_node(content);
        return new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", "libdino-incoming-jingle-s5b")
            .put_attribute("from", peer.to_string())
            .put_attribute("to", "alice@example.test/dinox")
            .put_node(jingle);
    }

    private StanzaNode build_test_jet_security_node(uint8 expected_tag) {
        return new StanzaNode.build("security", NS_JET)
            .add_self_xmlns()
            .put_attribute("cipher", NS_TEST_JET_CIPHER)
            .put_attribute("type", NS_TEST_JET_TYPE)
            .put_attribute("test-key", "5a")
            .put_attribute("test-tag", ((int) expected_tag).to_string());
    }

    private uint8[] xor_payload(uint8[] payload, uint8 key) {
        uint8[] result = new uint8[payload.length];
        for (int i = 0; i < payload.length; i++) {
            result[i] = (uint8) (payload[i] ^ key);
        }
        return result;
    }

    private uint8 test_plaintext_tag(uint8[] payload) {
        uint checksum = 0;
        for (int i = 0; i < payload.length; i++) {
            checksum = (checksum + payload[i]) & 0xff;
        }
        return (uint8) checksum;
    }

    private StanzaNode build_incoming_jingle_s5b_iq_with_candidate(Xmpp.Jid local, Xmpp.Jid peer, string sid, string content_name, string s5b_sid,
            string file_name, int64 file_size, string candidate_cid, string candidate_host, int candidate_port) throws Error {
        string dstaddr = Xmpp.Xep.JingleSocks5Bytestreams.calculate_dstaddr(s5b_sid, peer, local);
        StanzaNode transport = new StanzaNode.build("transport", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns)
            .add_self_xmlns()
            .put_attribute("mode", "tcp")
            .put_attribute("sid", s5b_sid)
            .put_attribute("dstaddr", dstaddr)
            .put_node(new StanzaNode.build("candidate", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns)
                .put_attribute("cid", candidate_cid)
                .put_attribute("host", candidate_host)
                .put_attribute("jid", peer.to_string())
                .put_attribute("port", candidate_port.to_string())
                .put_attribute("priority", "8267775")
                .put_attribute("type", "direct"));
        StanzaNode content = new StanzaNode.build("content", "urn:xmpp:jingle:1")
            .put_attribute("creator", "initiator")
            .put_attribute("name", content_name)
            .put_attribute("senders", "initiator")
            .put_node(build_jingle_file_description(file_name, file_size.to_string()))
            .put_node(transport);
        StanzaNode jingle = new StanzaNode.build("jingle", "urn:xmpp:jingle:1")
            .add_self_xmlns()
            .put_attribute("action", "session-initiate")
            .put_attribute("initiator", peer.to_string())
            .put_attribute("sid", sid)
            .put_node(content);
        return new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", "libdino-incoming-jingle-s5b-account-proxy")
            .put_attribute("from", peer.to_string())
            .put_attribute("to", local.to_string())
            .put_node(jingle);
    }

    private StanzaNode build_jingle_file_description(string file_name, string file_size) {
        var description = new StanzaNode.build("description", Xmpp.Xep.JingleFileTransfer.Module.IDENTITY.ns).add_self_xmlns();
        var file = new StanzaNode.build("file", Xmpp.Xep.JingleFileTransfer.Module.IDENTITY.ns)
            .put_node(new StanzaNode.build("name", Xmpp.Xep.JingleFileTransfer.Module.IDENTITY.ns)
                .put_node(new StanzaNode.text(file_name)))
            .put_node(new StanzaNode.build("size", Xmpp.Xep.JingleFileTransfer.Module.IDENTITY.ns)
                .put_node(new StanzaNode.text(file_size)));
        description.put_node(file);
        return description;
    }

    private StanzaNode build_ibb_open(string sid, int block_size) {
        return new StanzaNode.build("open", "http://jabber.org/protocol/ibb")
            .add_self_xmlns()
            .put_attribute("sid", sid)
            .put_attribute("block-size", block_size.to_string())
            .put_attribute("stanza", "iq");
    }

    private StanzaNode build_ibb_data(string sid, int seq, uint8[] payload) {
        return new StanzaNode.build("data", "http://jabber.org/protocol/ibb")
            .add_self_xmlns()
            .put_attribute("sid", sid)
            .put_attribute("seq", seq.to_string())
            .put_node(new StanzaNode.text(Base64.encode(payload)));
    }

    private StanzaNode build_ibb_close(string sid) {
        return new StanzaNode.build("close", "http://jabber.org/protocol/ibb")
            .add_self_xmlns()
            .put_attribute("sid", sid);
    }

    private StanzaNode build_s5b_candidate_used_transport_info(Xmpp.Jid peer, string sid, string content_name, string s5b_sid, string cid, string iq_id) {
        StanzaNode transport = new StanzaNode.build("transport", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns)
            .add_self_xmlns()
            .put_attribute("sid", s5b_sid)
            .put_node(new StanzaNode.build("candidate-used", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns)
                .put_attribute("cid", cid));
        StanzaNode content = new StanzaNode.build("content", "urn:xmpp:jingle:1")
            .put_attribute("creator", "initiator")
            .put_attribute("name", content_name)
            .put_attribute("senders", "initiator")
            .put_node(transport);
        StanzaNode jingle = new StanzaNode.build("jingle", "urn:xmpp:jingle:1")
            .add_self_xmlns()
            .put_attribute("action", "transport-info")
            .put_attribute("initiator", peer.to_string())
            .put_attribute("sid", sid)
            .put_node(content);
        return new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", iq_id)
            .put_attribute("from", peer.to_string())
            .put_attribute("to", "alice@example.test/dinox")
            .put_node(jingle);
    }

    private StanzaNode build_s5b_candidate_error_transport_info(Xmpp.Jid local, Xmpp.Jid peer, string sid, string content_name, string s5b_sid, string iq_id) {
        StanzaNode transport = new StanzaNode.build("transport", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns)
            .add_self_xmlns()
            .put_attribute("sid", s5b_sid)
            .put_node(new StanzaNode.build("candidate-error", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns));
        StanzaNode content = new StanzaNode.build("content", "urn:xmpp:jingle:1")
            .put_attribute("creator", "initiator")
            .put_attribute("name", content_name)
            .put_attribute("senders", "initiator")
            .put_node(transport);
        StanzaNode jingle = new StanzaNode.build("jingle", "urn:xmpp:jingle:1")
            .add_self_xmlns()
            .put_attribute("action", "transport-info")
            .put_attribute("initiator", peer.to_string())
            .put_attribute("sid", sid)
            .put_node(content);
        return new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", iq_id)
            .put_attribute("from", peer.to_string())
            .put_attribute("to", local.to_string())
            .put_node(jingle);
    }

    private StanzaNode build_iq_result(StanzaNode request, Xmpp.Jid from, Xmpp.Jid to) {
        string? id = request.get_attribute("id");
        fail_if(id == null, "test IQ result request must have an id");
        return new StanzaNode.build("iq")
            .put_attribute("type", "result")
            .put_attribute("id", (!) id)
            .put_attribute("from", from.to_string())
            .put_attribute("to", to.to_string());
    }

    private StanzaNode build_disco_info_result(StanzaNode request, Xmpp.Jid from, Xmpp.Jid to, string[] features) {
        StanzaNode result = build_iq_result(request, from, to);
        StanzaNode query = new StanzaNode.build("query", Xmpp.Xep.ServiceDiscovery.NS_URI_INFO)
            .add_self_xmlns()
            .put_node(new StanzaNode.build("identity", Xmpp.Xep.ServiceDiscovery.NS_URI_INFO)
                .put_attribute("category", "client")
                .put_attribute("type", "pc")
                .put_attribute("name", "DinoX Test"));
        foreach (string feature in features) {
            query.put_node(new StanzaNode.build("feature", Xmpp.Xep.ServiceDiscovery.NS_URI_INFO)
                .put_attribute("var", feature));
        }
        return result.put_node(query);
    }

    private StanzaNode? wait_for_disco_info_request(FileManagerJingleTestXmppStream stream, Xmpp.Jid peer, uint timeout_ms) {
        StanzaNode? request = find_written_disco_info_request(stream, peer);
        if (request != null) return request;

        var loop = new MainLoop();
        uint poll_source = 0;
        uint timeout_source = 0;

        poll_source = Timeout.add(25, () => {
            request = find_written_disco_info_request(stream, peer);
            if (request != null) {
                poll_source = 0;
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });

        timeout_source = Timeout.add(timeout_ms, () => {
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        return request ?? find_written_disco_info_request(stream, peer);
    }

    private StanzaNode? find_written_disco_info_request(FileManagerJingleTestXmppStream stream, Xmpp.Jid peer) {
        foreach (StanzaNode iq in stream.written_nodes) {
            if (iq.name != "iq" || iq.get_attribute("type") != "get" || iq.get_attribute("to") != peer.to_string()) continue;
            StanzaNode? query = iq.get_subnode("query", Xmpp.Xep.ServiceDiscovery.NS_URI_INFO);
            if (query != null) return iq;
        }
        return null;
    }

    private void run_jingle_iq_set(FileManagerJingleTestXmppStream stream, StanzaNode iq_node) throws Error {
        var jingle = stream.get_module<Xmpp.Xep.Jingle.Module>(Xmpp.Xep.Jingle.Module.IDENTITY);
        fail_if(jingle == null, "test setup must attach the Jingle module");
        var iq = new Xmpp.Iq.Stanza.from_stanza(iq_node, stream.get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid);

        Error? failure = null;
        var loop = new MainLoop();
        ((!) jingle).handle_iq_set.begin(stream, iq, (_, res) => {
            try {
                ((!) jingle).handle_iq_set.end(res);
            } catch (Error e) {
                failure = e;
            }
            loop.quit();
        });
        loop.run();
        if (failure != null) {
            throw (!) failure;
        }
    }

    private void run_ibb_iq_set(FileManagerJingleTestXmppStream stream, Xmpp.Jid peer, StanzaNode ibb_node, string iq_id) throws Error {
        var ibb = stream.get_module<Xmpp.Xep.InBandBytestreams.Module>(Xmpp.Xep.InBandBytestreams.Module.IDENTITY);
        fail_if(ibb == null, "test setup must attach the IBB module");

        StanzaNode iq_node = new StanzaNode.build("iq")
            .put_attribute("type", "set")
            .put_attribute("id", iq_id)
            .put_attribute("from", peer.to_string())
            .put_attribute("to", "alice@example.test/dinox")
            .put_node(ibb_node);
        var iq = new Xmpp.Iq.Stanza.from_stanza(iq_node, stream.get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid);

        var loop = new MainLoop();
        ((!) ibb).on_iq_set.begin(stream, iq, (_, res) => {
            ((!) ibb).on_iq_set.end(res);
            loop.quit();
        });
        loop.run();
    }

    private StanzaNode get_required_subnode(StanzaNode node, string name, string ns_uri) {
        StanzaNode? child = node.get_subnode(name, ns_uri);
        fail_if(child == null, @"expected <$name/> child in namespace $ns_uri");
        return (!) child;
    }

    private void assert_last_session_terminate_reason(FileManagerJingleTestXmppStream stream, string sid, Xmpp.Jid peer, string reason_name) {
        fail_if(stream.written_nodes.is_empty,
            "incoming Jingle provider auto-download must write a final Jingle stanza");
        StanzaNode iq = stream.written_nodes[stream.written_nodes.size - 1];
        fail_if(iq.name != "iq", "final Jingle stanza must be an IQ");
        fail_if(iq.get_attribute("type") != "set", "final Jingle stanza must be an IQ set");
        fail_if(iq.get_attribute("to") != peer.to_string(), "final Jingle stanza must target the sender");
        StanzaNode jingle = get_required_subnode(iq, "jingle", "urn:xmpp:jingle:1");
        fail_if(jingle.get_attribute("action") != "session-terminate",
            "incoming Jingle provider auto-download must terminate the session after store");
        fail_if(jingle.get_attribute("sid") != sid,
            "incoming Jingle provider auto-download must terminate the original SID");
        StanzaNode reason = get_required_subnode(jingle, "reason", "urn:xmpp:jingle:1");
        fail_if(reason.get_subnode(reason_name, "urn:xmpp:jingle:1") == null,
            "incoming Jingle provider auto-download must terminate with success");
    }

    private bool wait_for_written_jingle_action(FileManagerJingleTestXmppStream stream, string sid, string action, uint timeout_ms) {
        if (find_written_jingle_action(stream, sid, action) != null) return true;

        var loop = new MainLoop();
        bool found = false;
        uint poll_source = 0;
        uint timeout_source = 0;

        poll_source = Timeout.add(25, () => {
            found = find_written_jingle_action(stream, sid, action) != null;
            if (found) {
                poll_source = 0;
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });

        timeout_source = Timeout.add(timeout_ms, () => {
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        return found || find_written_jingle_action(stream, sid, action) != null;
    }

    private StanzaNode? find_written_jingle_action(FileManagerJingleTestXmppStream stream, string sid, string action) {
        foreach (StanzaNode iq in stream.written_nodes) {
            StanzaNode? jingle = iq.get_subnode("jingle", "urn:xmpp:jingle:1");
            if (jingle != null &&
                    ((!) jingle).get_attribute("sid") == sid &&
                    ((!) jingle).get_attribute("action") == action) {
                return (!) jingle;
            }
        }
        return null;
    }

    private StanzaNode require_written_jingle_action(FileManagerJingleTestXmppStream stream, string sid, string action) {
        StanzaNode? result = find_written_jingle_action(stream, sid, action);
        fail_if(result == null, @"expected written Jingle $action for sid $sid");
        return (!) result;
    }

    private bool wait_for_written_socks5_activation_iq(FileManagerJingleTestXmppStream stream, string s5b_sid,
            Xmpp.Jid proxy_jid, Xmpp.Jid peer, uint timeout_ms) {
        if (find_written_socks5_activation_iq(stream, s5b_sid, proxy_jid, peer) != null) return true;

        var loop = new MainLoop();
        bool found = false;
        uint poll_source = 0;
        uint timeout_source = 0;

        poll_source = Timeout.add(25, () => {
            found = find_written_socks5_activation_iq(stream, s5b_sid, proxy_jid, peer) != null;
            if (found) {
                poll_source = 0;
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });

        timeout_source = Timeout.add(timeout_ms, () => {
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        return found || find_written_socks5_activation_iq(stream, s5b_sid, proxy_jid, peer) != null;
    }

    private StanzaNode? find_written_socks5_activation_iq(FileManagerJingleTestXmppStream stream, string s5b_sid,
            Xmpp.Jid proxy_jid, Xmpp.Jid peer) {
        foreach (StanzaNode iq in stream.written_nodes) {
            if (iq.name != "iq" ||
                    iq.get_attribute("type") != "set" ||
                    iq.get_attribute("to") != proxy_jid.to_string()) {
                continue;
            }
            StanzaNode? query = iq.get_subnode("query", "http://jabber.org/protocol/bytestreams");
            if (query == null || ((!) query).get_attribute("sid") != s5b_sid) {
                continue;
            }
            StanzaNode? activate = ((!) query).get_subnode("activate", "http://jabber.org/protocol/bytestreams");
            if (activate != null && ((!) activate).get_string_content() == peer.to_string()) {
                return iq;
            }
        }
        return null;
    }

    private StanzaNode require_written_socks5_activation_iq(FileManagerJingleTestXmppStream stream, string s5b_sid,
            Xmpp.Jid proxy_jid, Xmpp.Jid peer) {
        StanzaNode? result = find_written_socks5_activation_iq(stream, s5b_sid, proxy_jid, peer);
        fail_if(result == null, @"expected written SOCKS5 activation IQ for sid $s5b_sid");
        return (!) result;
    }

    private bool wait_for_written_s5b_transport_info_child(FileManagerJingleTestXmppStream stream, string sid, string content_name,
            string s5b_sid, string child_name, string? cid, uint timeout_ms) {
        if (find_written_s5b_transport_info_child(stream, sid, content_name, s5b_sid, child_name, cid) != null) return true;

        var loop = new MainLoop();
        bool found = false;
        uint poll_source = 0;
        uint timeout_source = 0;

        poll_source = Timeout.add(25, () => {
            found = find_written_s5b_transport_info_child(stream, sid, content_name, s5b_sid, child_name, cid) != null;
            if (found) {
                poll_source = 0;
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });

        timeout_source = Timeout.add(timeout_ms, () => {
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        return found || find_written_s5b_transport_info_child(stream, sid, content_name, s5b_sid, child_name, cid) != null;
    }

    private StanzaNode? find_written_s5b_transport_info_child(FileManagerJingleTestXmppStream stream, string sid, string content_name,
            string s5b_sid, string child_name, string? cid) {
        foreach (StanzaNode iq in stream.written_nodes) {
            StanzaNode? jingle = iq.get_subnode("jingle", "urn:xmpp:jingle:1");
            if (jingle == null ||
                    ((!) jingle).get_attribute("sid") != sid ||
                    ((!) jingle).get_attribute("action") != "transport-info") {
                continue;
            }
            foreach (StanzaNode content in ((!) jingle).get_subnodes("content", "urn:xmpp:jingle:1")) {
                if (content.get_attribute("name") != content_name) continue;
                StanzaNode? transport = content.get_subnode("transport", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns);
                if (transport == null || ((!) transport).get_attribute("sid") != s5b_sid) continue;
                StanzaNode? child = ((!) transport).get_subnode(child_name, Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns);
                if (child != null && (cid == null || ((!) child).get_attribute("cid") == (!) cid)) {
                    return (!) child;
                }
            }
        }
        return null;
    }

    private StanzaNode get_single_candidate_by_type(StanzaNode transport, string type_) {
        StanzaNode? result = null;
        foreach (StanzaNode candidate in transport.get_subnodes("candidate", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns)) {
            if (candidate.get_attribute("type") != type_) continue;
            fail_if(result != null, @"expected only one $type_ S5B candidate");
            result = candidate;
        }
        fail_if(result == null, @"expected one $type_ S5B candidate");
        return (!) result;
    }

    private void assert_only_s5b_candidate_type(StanzaNode transport, string type_) {
        int count = 0;
        foreach (StanzaNode candidate in transport.get_subnodes("candidate", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns)) {
            count++;
            fail_if(candidate.get_attribute("type") != type_,
                @"incoming Jingle S5B provider auto-download must publish only $type_ candidates");
        }
        fail_if(count != 1, @"incoming Jingle S5B provider auto-download must publish exactly one $type_ candidate");
    }

    private void assert_no_jingle_session_state(FileManagerJingleTestXmppStream stream, string sid) {
        var jingle_flag = stream.get_flag(Xmpp.Xep.Jingle.Flag.IDENTITY);
        fail_if(jingle_flag != null && ((!) jingle_flag).promises.has_key(sid),
            "incoming Jingle provider auto-download must not leave promise state after termination");
        fail_if(jingle_flag != null && ((!) jingle_flag).sessions.has_key(sid),
            "incoming Jingle provider auto-download must not leave session state after termination");
    }

    private SocketConnection run_connect_to_socks5(Xmpp.Xep.JingleSocks5Bytestreams.Candidate candidate, string dstaddr) throws Error {
        SocketConnection? result = null;
        Error? failure = null;
        Cancellable cancellable = new Cancellable();
        bool timed_out = false;
        var loop = new MainLoop();
        uint timeout_source = 0;

        timeout_source = Timeout.add(1000, () => {
            timed_out = true;
            timeout_source = 0;
            cancellable.cancel();
            loop.quit();
            return Source.REMOVE;
        });

        connect_to_socks5.begin(candidate, dstaddr, cancellable, (_, res) => {
            try {
                result = connect_to_socks5.end(res);
            } catch (Error e) {
                failure = e;
            }
            if (timeout_source != 0) {
                Source.remove(timeout_source);
                timeout_source = 0;
            }
            loop.quit();
        });
        loop.run();

        if (timeout_source != 0) Source.remove(timeout_source);
        if (timed_out) {
            if (result != null) {
                try { ((!) result).close(); } catch (Error e) {}
            }
            throw new IOError.TIMED_OUT("Timed out completing S5B listener handshake");
        }
        if (failure != null) throw (!) failure;
        return (!) result;
    }

    private async SocketConnection connect_to_socks5(Xmpp.Xep.JingleSocks5Bytestreams.Candidate candidate, string dstaddr, Cancellable cancellable) throws Error {
        SocketClient socket_client = new SocketClient() { timeout=2 };
        socket_client.set_proxy_resolver(new SimpleProxyResolver("direct://", null));
        SocketConnection? conn = null;
        try {
            conn = yield socket_client.connect_to_host_async(@"[$(candidate.host)]:$(candidate.port)", 0, cancellable);

            size_t written;
            size_t read;
            uint8[] read_buffer = new uint8[1024];
            ByteArray write_buffer = new ByteArray();

            yield ((!) conn).output_stream.write_all_async({0x05, 0x01, 0x00}, Priority.DEFAULT, cancellable, out written);

            yield ((!) conn).input_stream.read_all_async(read_buffer[0:2], Priority.DEFAULT, cancellable, out read);
            if (read != 2 || read_buffer[0] != 0x05 || read_buffer[1] != 0x00) {
                throw new IOError.PROXY_FAILED("S5B listener did not accept null authentication");
            }

            write_buffer.append({0x05, 0x01, 0x00, 0x03});
            write_buffer.append({(uint8) dstaddr.length});
            write_buffer.append(dstaddr.data);
            write_buffer.append({0x00, 0x00});
            yield ((!) conn).output_stream.write_all_async(write_buffer.data, Priority.DEFAULT, cancellable, out written);

            yield ((!) conn).input_stream.read_all_async(read_buffer[0:write_buffer.len], Priority.DEFAULT, cancellable, out read);
            if (read != write_buffer.len || read_buffer[0] != 0x05 || read_buffer[1] != 0x00 || read_buffer[3] != 0x03) {
                throw new IOError.PROXY_FAILED("S5B listener did not complete the connect handshake");
            }
            if (read_buffer[4] != (uint8) dstaddr.length ||
                    !Xmpp.Xep.JingleSocks5Bytestreams.bytes_equal(read_buffer[5:5 + dstaddr.length], dstaddr.data) ||
                    read_buffer[5 + dstaddr.length] != 0x00 ||
                    read_buffer[5 + dstaddr.length + 1] != 0x00) {
                throw new IOError.PROXY_FAILED("S5B listener returned an unexpected dstaddr success response");
            }

            SocketConnection result = (!) conn;
            conn = null;
            return result;
        } catch (Error e) {
            if (conn != null) {
                try { ((!) conn).close(); } catch (Error close_error) {}
            }
            throw e;
        }
    }

    private void drain_s5b_listener_bookkeeping() {
        var loop = new MainLoop();
        uint timeout_source = 0;
        timeout_source = Timeout.add(100, () => {
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });
        loop.run();
        if (timeout_source != 0) Source.remove(timeout_source);
    }

    private void run_write_all_stream(OutputStream output, uint8[] payload) throws Error {
        Error? failure = null;
        bool timed_out = false;
        uint timeout_source = 0;
        size_t written = 0;
        Cancellable cancellable = new Cancellable();
        var loop = new MainLoop();

        timeout_source = Timeout.add(1000, () => {
            timed_out = true;
            timeout_source = 0;
            cancellable.cancel();
            loop.quit();
            return Source.REMOVE;
        });
        output.write_all_async.begin(payload, Priority.DEFAULT, cancellable, (_, res) => {
            try {
                output.write_all_async.end(res, out written);
            } catch (Error e) {
                failure = e;
            }
            if (timeout_source != 0) {
                Source.remove(timeout_source);
                timeout_source = 0;
            }
            loop.quit();
        });
        loop.run();
        if (timeout_source != 0) Source.remove(timeout_source);
        if (timed_out) {
            throw new IOError.TIMED_OUT("Timed out writing S5B payload");
        }
        if (failure != null) throw (!) failure;
        fail_if(written != payload.length, "S5B payload write must complete");
    }

    private void run_connect_to_onion_through_tor(FileManagerLocalTorSocksDaemon tor, string onion_hostname, int onion_port, uint timeout_ms) throws Error {
        Error? failure = null;
        Cancellable cancellable = new Cancellable();
        bool timed_out = false;
        var loop = new MainLoop();
        uint timeout_source = 0;
        timeout_source = Timeout.add(timeout_ms, () => {
            timed_out = true;
            timeout_source = 0;
            cancellable.cancel();
            return Source.REMOVE;
        });
        connect_to_onion_through_tor.begin(tor, onion_hostname, onion_port, cancellable, (obj, res) => {
            try {
                connect_to_onion_through_tor.end(res);
            } catch (Error e) {
                failure = e;
            }
            if (timeout_source != 0) {
                Source.remove(timeout_source);
                timeout_source = 0;
            }
            loop.quit();
        });
        loop.run();
        if (timeout_source != 0) {
            Source.remove(timeout_source);
        }
        if (timed_out) {
            throw new IOError.TIMED_OUT("Timed out warming up FileManager Tor onion S5B target");
        }
        if (failure != null) {
            throw (!) failure;
        }
    }

    private async void connect_to_onion_through_tor(FileManagerLocalTorSocksDaemon tor, string onion_hostname, int onion_port,
            Cancellable cancellable) throws Error {
        SocketClient socket_client = new SocketClient() { timeout=180 };
        socket_client.set_proxy_resolver(new SimpleProxyResolver("direct://", null));
        SocketConnection? conn = null;
        try {
            conn = yield socket_client.connect_to_host_async("127.0.0.1:%d".printf(tor.port), 0, cancellable);
            yield perform_onion_warmup_socks_connect((!) conn, onion_hostname, onion_port, cancellable);
        } catch (Error e) {
            if (conn != null) {
                try {
                    ((!) conn).close();
                } catch (Error close_error) {
                }
            }
            throw e;
        }
        ((!) conn).close();
    }

    private async void perform_onion_warmup_socks_connect(SocketConnection conn, string onion_hostname, int onion_port,
            Cancellable cancellable) throws Error {
        size_t read;
        size_t written;
        uint8[] read_buffer = new uint8[1024];
        ByteArray write_buffer = new ByteArray();

        yield conn.output_stream.write_all_async({0x05, 0x01, 0x00}, Priority.DEFAULT, cancellable, out written);
        yield conn.input_stream.read_all_async(read_buffer[0:2], Priority.DEFAULT, cancellable, out read);
        if (read != 2 || read_buffer[0] != 0x05 || read_buffer[1] != 0x00) {
            throw new IOError.PROXY_FAILED("FileManager Tor onion warmup SOCKS proxy did not accept null authentication");
        }

        write_buffer.append({0x05, 0x01, 0x00, 0x03});
        write_buffer.append({(uint8) onion_hostname.length});
        write_buffer.append(onion_hostname.data);
        write_buffer.append({(uint8)((onion_port >> 8) & 0xff), (uint8)(onion_port & 0xff)});
        yield conn.output_stream.write_all_async(write_buffer.data, Priority.DEFAULT, cancellable, out written);

        yield conn.input_stream.read_all_async(read_buffer[0:4], Priority.DEFAULT, cancellable, out read);
        if (read != 4 || read_buffer[0] != 0x05 || read_buffer[1] != 0x00) {
            throw new IOError.PROXY_FAILED("FileManager Tor onion warmup SOCKS proxy did not connect to the hidden service");
        }
        if (read_buffer[3] == 0x01) {
            yield conn.input_stream.read_all_async(read_buffer[0:6], Priority.DEFAULT, cancellable, out read);
        } else if (read_buffer[3] == 0x03) {
            yield conn.input_stream.read_all_async(read_buffer[0:1], Priority.DEFAULT, cancellable, out read);
            if (read != 1) {
                throw new IOError.PROXY_FAILED("FileManager Tor onion warmup SOCKS proxy returned an incomplete domain reply");
            }
            int host_len = read_buffer[0];
            yield conn.input_stream.read_all_async(read_buffer[0:host_len + 2], Priority.DEFAULT, cancellable, out read);
        } else if (read_buffer[3] == 0x04) {
            yield conn.input_stream.read_all_async(read_buffer[0:18], Priority.DEFAULT, cancellable, out read);
        } else {
            throw new IOError.PROXY_FAILED("FileManager Tor onion warmup SOCKS proxy returned an unsupported address type");
        }
    }

    private void cleanup_test_dir(string temp_dir) {
        DirUtils.remove(Path.build_filename(temp_dir, "dinox", "temp_plaintext", "pgp-send"));
        DirUtils.remove(Path.build_filename(temp_dir, "dinox", "temp_plaintext", "pgp-receive"));
        DirUtils.remove(Path.build_filename(temp_dir, "dinox", "temp_plaintext", "open"));
        DirUtils.remove(Path.build_filename(temp_dir, "dinox", "temp_plaintext"));
        DirUtils.remove(Path.build_filename(temp_dir, "dinox"));
        DirUtils.remove(temp_dir);
    }

    void test_save_outgoing_file_stores_encrypted_copy_sync() {
        var loop = new MainLoop();
        test_save_outgoing_file_stores_encrypted_copy.begin((obj, res) => {
            test_save_outgoing_file_stores_encrypted_copy.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_save_outgoing_file_stores_encrypted_copy() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var file_encryption = new Dino.Security.FileEncryption("save-test");
            uint8[] plaintext = "local outgoing plaintext\n".data;
            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "report.txt";
            file_transfer.size = plaintext.length;

            File committed_file = yield Dino.FileManager.save_outgoing_file_for_tests(
                    file_encryption, file_transfer, new MemoryInputStream.from_data(plaintext), temp_dir);

            fail_if(file_transfer.path == null, "saved outgoing file must publish a storage path after commit");
            fail_if_not_eq_str((!) file_transfer.path, committed_file.get_basename(),
                "saved outgoing path must point to the committed file");
            fail_if(!committed_file.query_exists(), "committed outgoing file must exist");
            fail_if(count_send_pending_files(temp_dir) != 0, "successful outgoing save must not leave pending files");

            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream(committed_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal(plaintext, decrypted), "stored outgoing file must decrypt to the original plaintext");
        } catch (Error e) {
            fail_if_reached(@"Outgoing save success test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_save_outgoing_large_stream_bounded_chunks_sync() {
        var loop = new MainLoop();
        test_save_outgoing_large_stream_bounded_chunks.begin((obj, res) => {
            test_save_outgoing_large_stream_bounded_chunks.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_save_outgoing_large_stream_bounded_chunks() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var file_encryption = new Dino.Security.FileEncryption("save-large-stream-test");
            var large_stream = new DeterministicLargeInputStream(LARGE_STREAM_BYTES);
            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "large-outgoing.bin";
            file_transfer.size = LARGE_STREAM_BYTES;

            File committed_file = yield Dino.FileManager.save_outgoing_file_for_tests(
                    file_encryption, file_transfer, large_stream, temp_dir);

            fail_if(file_transfer.path == null, "large outgoing save must publish a storage path");
            fail_if(!committed_file.query_exists(), "large outgoing save must commit the encrypted local copy");
            fail_if(count_send_pending_files(temp_dir) != 0, "large outgoing save must not leave pending send files");
            fail_if(large_stream.read_calls < 100,
                "large outgoing save must read the input stream incrementally");
            fail_if(large_stream.max_requested > 8192,
                "large outgoing save must not request chunks larger than the encryption buffer");
            fail_if(large_stream.max_returned > 8192,
                "large outgoing save must not return chunks larger than the encryption buffer");

            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream(committed_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            assert_pattern_bytes(decrypted, LARGE_STREAM_BYTES,
                "large outgoing local copy must decrypt to the original deterministic stream");
        } catch (Error e) {
            fail_if_reached(@"Large outgoing save test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_save_outgoing_file_cleans_pending_on_cancel_sync() {
        var loop = new MainLoop();
        test_save_outgoing_file_cleans_pending_on_cancel.begin((obj, res) => {
            test_save_outgoing_file_cleans_pending_on_cancel.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_save_outgoing_file_cleans_pending_on_cancel() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var file_encryption = new Dino.Security.FileEncryption("save-cancel-test");
            uint8[] plaintext = "cancelled outgoing plaintext\n".data;
            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "cancelled.txt";
            file_transfer.size = plaintext.length;
            file_transfer.cancellable.cancel();

            bool failed = false;
            try {
                yield Dino.FileManager.save_outgoing_file_for_tests(
                        file_encryption, file_transfer, new MemoryInputStream.from_data(plaintext), temp_dir);
            } catch (Dino.FileSendError.SAVE_FAILED e) {
                failed = true;
            }

            fail_if(!failed, "cancelled outgoing save must fail");
            fail_if(file_transfer.path != null, "cancelled outgoing save must not publish a storage path");
            fail_if(count_directory_entries(temp_dir) != 0, "cancelled outgoing save must clean pending and final files");
        } catch (Error e) {
            fail_if_reached(@"Outgoing save cancel test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_receive_metadata_cancel_keeps_transfer_unpublished_sync() {
        var loop = new MainLoop();
        test_receive_metadata_cancel_keeps_transfer_unpublished.begin((obj, res) => {
            test_receive_metadata_cancel_keeps_transfer_unpublished.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_receive_metadata_cancel_keeps_transfer_unpublished() {
        var provider = new TestCancellingMetadataProvider();
        var file_transfer = new Dino.Entities.FileTransfer();
        file_transfer.file_name = "transport.bin";
        file_transfer.mime_type = "application/octet-stream";
        file_transfer.size = -1;
        file_transfer.set_transfer_phase(Dino.Entities.FileTransfer.Phase.PREPARING);

        string original_name = file_transfer.file_name;
        string? original_mime_type = file_transfer.mime_type;
        int64 original_size = file_transfer.size;

        file_transfer.notify["phase"].connect(() => {
            fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.PREVIEWING,
                "cancelled provider metadata must not expose PREVIEWING");
            fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                "cancelled provider metadata must not expose COMPLETE");
        });

        bool cancelled = false;
        try {
            yield Dino.FileManager.prepare_provider_metadata_for_tests(provider, file_transfer, new Dino.FileReceiveData());
            fail_if_reached("cancelled provider metadata must not return successfully");
        } catch (IOError.CANCELLED e) {
            cancelled = true;
        } catch (Error e) {
            fail_if_reached(@"Unexpected provider metadata cancel error: $(e.message)");
        }

        fail_if(!cancelled, "cancelled provider metadata must propagate cancellation");
        fail_if(!provider.metadata_called, "provider metadata path must be exercised");
        fail_if(provider.download_called, "provider metadata cancellation must not start the download");
        fail_if_not_eq_str(file_transfer.file_name, original_name,
            "cancelled provider metadata must not publish filename");
        fail_if_not_eq_str(file_transfer.mime_type, original_mime_type,
            "cancelled provider metadata must not publish MIME type");
        fail_if(file_transfer.size != original_size,
            "cancelled provider metadata must not publish transport size");
        fail_if(file_transfer.path != null,
            "cancelled provider metadata must not publish a storage path");
        fail_if(file_transfer.is_plaintext_release_allowed(),
            "cancelled provider metadata must not allow plaintext release");
        fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
            "cancelled provider metadata must not complete the transfer");
    }

    void test_receive_store_cancel_cleans_pending_before_publish_sync() {
        var loop = new MainLoop();
        test_receive_store_cancel_cleans_pending_before_publish.begin((obj, res) => {
            test_receive_store_cancel_cleans_pending_before_publish.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_receive_store_cancel_cleans_pending_before_publish() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var file_encryption = new Dino.Security.FileEncryption("receive-store-cancel-test");
            uint8[] plaintext = "cancelled received plaintext\n".data;
            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "received.txt";
            file_transfer.mime_type = "text/plain";
            file_transfer.size = 98765;
            file_transfer.cancellable.cancel();
            string original_name = file_transfer.file_name;
            string? original_mime_type = file_transfer.mime_type;
            int64 original_size = file_transfer.size;

            file_transfer.notify["phase"].connect(() => {
                fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.PREVIEWING,
                    "cancelled receive store must not expose PREVIEWING");
                fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                    "cancelled receive store must not expose COMPLETE");
            });

            bool cancelled = false;
            try {
                yield Dino.FileManager.store_received_file_for_tests(
                        file_encryption, file_transfer, new MemoryInputStream.from_data(plaintext), temp_dir);
            } catch (IOError.CANCELLED e) {
                cancelled = true;
            } catch (Error e) {
                fail_if_reached(@"Unexpected receive store cancel error: $(e.message)");
            }

            fail_if(!cancelled, "cancelled receive store must propagate cancellation");
            fail_if_not_eq_str(file_transfer.file_name, original_name, "cancelled receive store must not change filename");
            fail_if_not_eq_str(file_transfer.mime_type, original_mime_type, "cancelled receive store must not change MIME type");
            fail_if(file_transfer.size != original_size, "cancelled receive store must not publish plaintext size");
            fail_if(file_transfer.path != null, "cancelled receive store must not publish a storage path");
            fail_if(file_transfer.is_plaintext_release_allowed(), "cancelled receive store must not allow plaintext release");
            fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                "cancelled receive store must not complete the transfer");
            fail_if(count_directory_entries(temp_dir) != 0, "cancelled receive store must clean pending files");
        } catch (Error e) {
            fail_if_reached(@"Receive store cancel test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_receive_store_hash_mismatch_cleans_pending_before_publish_sync() {
        var loop = new MainLoop();
        test_receive_store_hash_mismatch_cleans_pending_before_publish.begin((obj, res) => {
            test_receive_store_hash_mismatch_cleans_pending_before_publish.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_receive_store_hash_mismatch_cleans_pending_before_publish() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var file_encryption = new Dino.Security.FileEncryption("receive-store-hash-test");
            uint8[] plaintext = "received plaintext with hash mismatch\n".data;
            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "report.txt";
            file_transfer.mime_type = "text/plain";
            file_transfer.size = 98765;
            string original_name = file_transfer.file_name;
            string? original_mime_type = file_transfer.mime_type;
            int64 original_size = file_transfer.size;

            uint8[] wrong_sha256 = new uint8[32];
            file_transfer.hashes.add(new Xmpp.Xep.CryptographicHashes.Hash.with_checksum(ChecksumType.SHA256, Base64.encode(wrong_sha256)));

            bool saw_verifying_phase = false;
            file_transfer.notify["phase"].connect(() => {
                if (file_transfer.phase == Dino.Entities.FileTransfer.Phase.VERIFYING) {
                    saw_verifying_phase = true;
                    fail_if_not_eq_str(file_transfer.file_name, original_name,
                        "receive store hash verification must not publish verified plaintext filename");
                    fail_if_not_eq_str(file_transfer.mime_type, original_mime_type,
                        "receive store hash verification must not publish verified plaintext MIME");
                    fail_if(file_transfer.path != null, "receive store hash verification must not publish the path");
                    fail_if(file_transfer.size != original_size, "receive store hash verification must not publish plaintext size");
                    fail_if(file_transfer.is_plaintext_release_allowed(),
                        "receive store hash verification must not allow plaintext release");
                }
                fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.PREVIEWING,
                    "receive store hash mismatch must not expose PREVIEWING");
                fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                    "receive store hash mismatch must not expose COMPLETE");
            });

            bool rejected = false;
            try {
                GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING, "*Hash mismatch for 'report.txt'*");
                yield Dino.FileManager.store_received_file_for_tests(
                        file_encryption, file_transfer, new MemoryInputStream.from_data(plaintext), temp_dir);
                fail_if_reached("receive store hash mismatch must fail before publish");
            } catch (Dino.FileReceiveError.DECRYPTION_FAILED e) {
                GLib.Test.assert_expected_messages();
                rejected = true;
            } catch (Error e) {
                fail_if_reached(@"Unexpected receive store hash mismatch error: $(e.message)");
            }

            fail_if(!rejected, "receive store hash mismatch must be rejected");
            fail_if(!saw_verifying_phase, "receive store hash mismatch must expose VERIFYING before rejection");
            fail_if_not_eq_str(file_transfer.file_name, original_name, "receive store hash mismatch must not change filename");
            fail_if_not_eq_str(file_transfer.mime_type, original_mime_type, "receive store hash mismatch must not change MIME type");
            fail_if(file_transfer.size != original_size, "receive store hash mismatch must not publish plaintext size");
            fail_if(file_transfer.path != null, "receive store hash mismatch must not publish a storage path");
            fail_if(file_transfer.is_plaintext_release_allowed(), "receive store hash mismatch must not allow plaintext release");
            fail_if(count_directory_entries(temp_dir) != 0, "receive store hash mismatch must clean pending files");
        } catch (Error e) {
            fail_if_reached(@"Receive store hash mismatch test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_receive_store_empty_media_cleans_pending_before_publish_sync() {
        var loop = new MainLoop();
        test_receive_store_empty_media_cleans_pending_before_publish.begin((obj, res) => {
            test_receive_store_empty_media_cleans_pending_before_publish.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_receive_store_empty_media_cleans_pending_before_publish() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var file_encryption = new Dino.Security.FileEncryption("receive-store-empty-media-test");
            uint8[] empty_payload = new uint8[0];
            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "broken-video.MP4";
            file_transfer.mime_type = "application/octet-stream";
            file_transfer.size = 98765;
            string original_name = file_transfer.file_name;
            string? original_mime_type = file_transfer.mime_type;
            int64 original_size = file_transfer.size;

            bool saw_verifying_phase = false;
            file_transfer.notify["phase"].connect(() => {
                if (file_transfer.phase == Dino.Entities.FileTransfer.Phase.VERIFYING) {
                    saw_verifying_phase = true;
                    fail_if_not_eq_str(file_transfer.file_name, original_name,
                        "empty media verification must not publish verified filename");
                    fail_if_not_eq_str(file_transfer.mime_type, original_mime_type,
                        "empty media verification must not publish verified MIME type");
                    fail_if(file_transfer.path != null,
                        "empty media verification must not publish the path");
                    fail_if(file_transfer.size != original_size,
                        "empty media verification must not publish plaintext size");
                    fail_if(file_transfer.is_plaintext_release_allowed(),
                        "empty media verification must not allow plaintext release");
                }
                fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.PREVIEWING,
                    "empty media receive store must not expose PREVIEWING");
                fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                    "empty media receive store must not expose COMPLETE");
            });

            bool rejected = false;
            try {
                yield Dino.FileManager.store_received_file_for_tests(
                        file_encryption, file_transfer, new MemoryInputStream.from_data(empty_payload), temp_dir);
                fail_if_reached("empty media receive store must fail before publish");
            } catch (Dino.FileReceiveError.DECRYPTION_FAILED e) {
                rejected = true;
                fail_if(!e.message.contains("Received media file is empty"),
                    "empty media rejection must keep a user-classifiable error message");
            } catch (Error e) {
                fail_if_reached(@"Unexpected empty media receive store error: $(e.message)");
            }

            fail_if(!rejected, "empty media receive store must be rejected");
            fail_if(!saw_verifying_phase, "empty media receive store must expose VERIFYING before rejection");
            fail_if_not_eq_str(file_transfer.file_name, original_name,
                "empty media receive store must not change filename");
            fail_if_not_eq_str(file_transfer.mime_type, original_mime_type,
                "empty media receive store must not change MIME type");
            fail_if(file_transfer.size != original_size,
                "empty media receive store must not publish plaintext size");
            fail_if(file_transfer.path != null,
                "empty media receive store must not publish a storage path");
            fail_if(file_transfer.is_plaintext_release_allowed(),
                "empty media receive store must not allow plaintext release");
            fail_if(count_directory_entries(temp_dir) != 0,
                "empty media receive store must clean pending files");
        } catch (Error e) {
            fail_if_reached(@"Empty media receive store test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_receive_store_accepts_worker_readable_async_only_stream_sync() {
        var loop = new MainLoop();
        test_receive_store_accepts_worker_readable_async_only_stream.begin((obj, res) => {
            test_receive_store_accepts_worker_readable_async_only_stream.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_receive_store_accepts_worker_readable_async_only_stream() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var file_encryption = new Dino.Security.FileEncryption("receive-async-only-store-test");
            uint8[] plaintext = "async-only incoming payload\n".data;
            var async_only_stream = new TestAsyncOnlyInputStream(plaintext);

            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "incoming-ibb.txt";
            file_transfer.mime_type = "text/plain";
            file_transfer.size = plaintext.length;

            File committed_file = yield Dino.FileManager.store_received_file_for_tests(
                    file_encryption, file_transfer, new Dino.WorkerReadableInputStream(async_only_stream), temp_dir);

            fail_if(!async_only_stream.read_async_called,
                "worker-readable receive store must use read_async on async-only streams");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "worker-readable async-only receive store must complete");
            fail_if(file_transfer.path == null, "worker-readable async-only receive store must publish a path");
            fail_if_not_eq_str((!) file_transfer.path, committed_file.get_basename(),
                "worker-readable async-only receive store path must point to the committed file");
            fail_if(file_transfer.size != plaintext.length,
                "worker-readable async-only receive store must publish plaintext size");
            fail_if(count_directory_entries(temp_dir) != 1,
                "worker-readable async-only receive store must leave only the committed file");

            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream(committed_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal(plaintext, decrypted),
                "worker-readable async-only receive store must persist the original plaintext");
        } catch (Error e) {
            fail_if_reached(@"Worker-readable async-only receive store test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_receive_store_worker_readable_async_only_cancel_cleans_pending_sync() {
        var loop = new MainLoop();
        test_receive_store_worker_readable_async_only_cancel_cleans_pending.begin((obj, res) => {
            test_receive_store_worker_readable_async_only_cancel_cleans_pending.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_receive_store_worker_readable_async_only_cancel_cleans_pending() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var file_encryption = new Dino.Security.FileEncryption("receive-async-only-cancel-test");
            var async_only_stream = new TestBlockingAsyncOnlyInputStream();

            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "cancelled-ibb.txt";
            file_transfer.mime_type = "text/plain";
            file_transfer.size = 4096;
            string original_name = file_transfer.file_name;
            string? original_mime_type = file_transfer.mime_type;
            int64 original_size = file_transfer.size;

            async_only_stream.read_started.connect(() => {
                file_transfer.cancellable.cancel();
            });

            file_transfer.notify["phase"].connect(() => {
                fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.PREVIEWING,
                    "cancelled worker-readable async-only receive store must not expose PREVIEWING");
                fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                    "cancelled worker-readable async-only receive store must not expose COMPLETE");
            });

            bool cancelled = false;
            try {
                yield Dino.FileManager.store_received_file_for_tests(
                        file_encryption, file_transfer, new Dino.WorkerReadableInputStream(async_only_stream), temp_dir);
                fail_if_reached("worker-readable async-only receive store cancellation must fail before publish");
            } catch (IOError.CANCELLED e) {
                cancelled = true;
            } catch (Error e) {
                fail_if_reached(@"Unexpected worker-readable async-only receive store cancel error: $(e.message)");
            }

            fail_if(!cancelled, "worker-readable async-only receive store must propagate cancellation");
            fail_if(!async_only_stream.read_async_called,
                "worker-readable async-only receive store cancellation must reach read_async");
            fail_if_not_eq_str(file_transfer.file_name, original_name,
                "cancelled worker-readable async-only receive store must not change filename");
            fail_if_not_eq_str(file_transfer.mime_type, original_mime_type,
                "cancelled worker-readable async-only receive store must not change MIME type");
            fail_if(file_transfer.size != original_size,
                "cancelled worker-readable async-only receive store must not publish plaintext size");
            fail_if(file_transfer.path != null,
                "cancelled worker-readable async-only receive store must not publish a storage path");
            fail_if(file_transfer.is_plaintext_release_allowed(),
                "cancelled worker-readable async-only receive store must not allow plaintext release");
            fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                "cancelled worker-readable async-only receive store must not complete the transfer");
            fail_if(count_directory_entries(temp_dir) != 0,
                "cancelled worker-readable async-only receive store must clean pending files");
        } catch (Error e) {
            fail_if_reached(@"Worker-readable async-only receive store cancel test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_receive_store_large_stream_bounded_chunks_sync() {
        var loop = new MainLoop();
        test_receive_store_large_stream_bounded_chunks.begin((obj, res) => {
            test_receive_store_large_stream_bounded_chunks.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_receive_store_large_stream_bounded_chunks() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var file_encryption = new Dino.Security.FileEncryption("receive-large-stream-test");
            var large_stream = new DeterministicLargeInputStream(LARGE_STREAM_BYTES);
            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "large-received.bin";
            file_transfer.mime_type = "application/octet-stream";
            file_transfer.size = LARGE_STREAM_BYTES;

            File committed_file = yield Dino.FileManager.store_received_file_for_tests(
                    file_encryption, file_transfer, large_stream, temp_dir);

            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "large receive store must finish in COMPLETE phase");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "large receive store must finish with COMPLETE state");
            fail_if(file_transfer.path == null, "large receive store must publish a storage path");
            fail_if(file_transfer.size != LARGE_STREAM_BYTES,
                "large receive store must publish the verified plaintext size");
            fail_if(!file_transfer.is_plaintext_release_allowed(),
                "large receive store must allow plaintext release only after verification and commit");
            fail_if(!committed_file.query_exists(), "large receive store must commit the encrypted local file");
            fail_if(count_receive_pending_files_for_basename(temp_dir, "large-received.bin") != 0,
                "large receive store must not leave pending receive files");
            fail_if(large_stream.read_calls < 100,
                "large receive store must read the input stream incrementally");
            fail_if(large_stream.max_requested > 8192,
                "large receive store must not request chunks larger than the encryption buffer");
            fail_if(large_stream.max_returned > 8192,
                "large receive store must not return chunks larger than the encryption buffer");

            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream(committed_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            assert_pattern_bytes(decrypted, LARGE_STREAM_BYTES,
                "large received local copy must decrypt to the original deterministic stream");
        } catch (Error e) {
            fail_if_reached(@"Large receive store test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_incoming_jingle_ibb_provider_auto_downloads_worker_readable_stream_sync() {
        var loop = new MainLoop();
        test_incoming_jingle_ibb_provider_auto_downloads_worker_readable_stream.begin((obj, res) => {
            test_incoming_jingle_ibb_provider_auto_downloads_worker_readable_stream.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_incoming_jingle_ibb_provider_auto_downloads_worker_readable_stream() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string incoming_file_name = "incoming-ibb-provider-" + Uuid.string_random() + ".txt";
        Dino.Database? db = null;
        string? stored_path = null;
        ulong received_handler = 0;
        Dino.FileManager? manager = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "incoming-jingle-ibb-provider-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.MessageStorage.start(stream_interactor, (!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);
            Dino.MessageProcessor.start(stream_interactor, (!) db);
            Dino.EntityInfo.start(stream_interactor, (!) db);
            Dino.RosterManager.start(stream_interactor, (!) db);
            Dino.Calls.start(stream_interactor, (!) db);
            Dino.ConversationManager.start(stream_interactor, (!) db);
            Dino.PresenceManager.start(stream_interactor, (!) db);
            Dino.MucManager.start(stream_interactor);

            var file_encryption = new Dino.Security.FileEncryption("incoming-jingle-ibb-provider-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            Xmpp.Jid bob_bare_jid = new Xmpp.Jid("bob@example.test");
            seed_trusted_roster_contact((!) db, account, bob_bare_jid);

            var conversation = new Dino.Entities.Conversation(bob_bare_jid, account, Dino.Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);

            stream_interactor.module_manager.initialize(account);
            var stream = new FileManagerJingleTestXmppStream(new Xmpp.Jid("example.test"));
            attach_jingle_ibb_modules_for_tests(stream_interactor, account, stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);
            stream_interactor.account_added(account);

            Dino.Entities.FileTransfer? published_transfer = null;
            Dino.Entities.Conversation? published_conversation = null;
            var publish_loop = new MainLoop();
            uint publish_timeout = 0;
            received_handler = ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                published_conversation = received_conversation;
                if (publish_timeout != 0) {
                    Source.remove(publish_timeout);
                    publish_timeout = 0;
                }
                publish_loop.quit();
            });

            uint8[] payload = "incoming jingle ibb provider payload\n".data;
            Xmpp.Jid peer = new Xmpp.Jid("bob@example.test/phone");
            StanzaNode iq = build_incoming_jingle_ibb_iq(peer, "libdino-incoming-ibb-provider", incoming_file_name, payload.length);
            run_jingle_iq_set(stream, iq);
            if (published_transfer == null) {
                publish_timeout = Timeout.add(5000, () => {
                    publish_timeout = 0;
                    publish_loop.quit();
                    return Source.REMOVE;
                });
                publish_loop.run();
            }
            if (publish_timeout != 0) {
                Source.remove(publish_timeout);
                publish_timeout = 0;
            }
            fail_if(published_transfer == null,
                "incoming Jingle provider must publish the received file transfer shell");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(published_conversation == null || ((!) published_conversation).id != conversation.id,
                "incoming Jingle provider must publish the one-to-one conversation");

            fail_if(!wait_for_ibb_connection(stream, "incoming-ibb-session", 5000),
                "incoming Jingle provider auto-download must accept the IBB transfer");
            run_ibb_iq_set(stream, peer, build_ibb_open("incoming-ibb-session", 4096), "libdino-ibb-open");
            run_ibb_iq_set(stream, peer, build_ibb_data("incoming-ibb-session", 0, payload), "libdino-ibb-data");
            run_ibb_iq_set(stream, peer, build_ibb_close("incoming-ibb-session"), "libdino-ibb-close");

            fail_if(!wait_for_transfer_phase(file_transfer, Dino.Entities.FileTransfer.Phase.COMPLETE, 5000),
                "incoming Jingle IBB provider auto-download must reach COMPLETE");
            stored_path = file_transfer.path;

            fail_if(file_transfer.id == -1, "incoming Jingle provider transfer must be persisted");
            fail_if(file_transfer.provider != 1, "incoming Jingle provider transfer must keep the Jingle provider id");
            fail_if(file_transfer.direction != Dino.Entities.FileTransfer.DIRECTION_RECEIVED,
                "incoming Jingle provider transfer must be received");
            fail_if(!file_transfer.counterpart.equals_bare(bob_bare_jid),
                "incoming Jingle provider transfer must keep the sender as counterpart");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "incoming Jingle provider transfer must persist complete state in memory");
            fail_if(file_transfer.size != payload.length,
                "incoming Jingle provider transfer must publish the verified plaintext size");
            fail_if(file_transfer.path == null, "incoming Jingle provider transfer must publish a storage path");
            fail_if(!file_transfer.is_plaintext_release_allowed(),
                "incoming Jingle provider transfer must allow plaintext release only after completion");
            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "incoming Jingle provider auto-download must persist COMPLETE state");

            Qlite.RowOption row = ((!) db).file_transfer.select()
                    .with(((!) db).file_transfer.id, "=", file_transfer.id)
                    .single()
                    .row();
            fail_if(!row.is_present(), "incoming Jingle provider transfer must have a database row");
            string? persisted_path = ((!) row.inner)[((!) db).file_transfer.path];
            int64 persisted_size = ((!) row.inner)[((!) db).file_transfer.size];
            fail_if(persisted_path == null || ((!) persisted_path) == "",
                "incoming Jingle provider auto-download must persist the storage path");
            fail_if(persisted_size != payload.length,
                "incoming Jingle provider auto-download must persist the plaintext size");

            File? stored_file = file_transfer.get_file();
            fail_if(stored_file == null || !((!) stored_file).query_exists(),
                "incoming Jingle provider auto-download must write the verified local file");
            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal(payload, decrypted),
                "incoming Jingle provider auto-download must persist the original IBB payload");
            fail_if(count_receive_pending_files_for_basename(Dino.FileManager.get_storage_dir(), incoming_file_name) != 0,
                "incoming Jingle provider auto-download must not leave pending receive files");
            assert_last_session_terminate_reason(stream, "libdino-incoming-ibb-provider", peer, "success");
        } catch (Error e) {
            fail_if_reached(@"Incoming Jingle IBB provider auto-download test failed: $(e.message)");
        } finally {
            if (received_handler != 0 && manager != null) {
                ((!) manager).disconnect(received_handler);
            }
            if (db != null) {
                ((!) db).close();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            delete_receive_pending_files_for_basename(Dino.FileManager.get_storage_dir(), incoming_file_name);
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_incoming_jingle_s5b_provider_auto_downloads_receive_store_sync() {
        var loop = new MainLoop();
        test_incoming_jingle_s5b_provider_auto_downloads_receive_store.begin((obj, res) => {
            test_incoming_jingle_s5b_provider_auto_downloads_receive_store.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_incoming_jingle_s5b_provider_auto_downloads_receive_store() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string incoming_file_name = "incoming-s5b-provider-" + Uuid.string_random() + ".txt";
        Dino.Database? db = null;
        string? stored_path = null;
        ulong received_handler = 0;
        Dino.FileManager? manager = null;
        SocketConnection? peer_connection = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "incoming-jingle-s5b-provider-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.MessageStorage.start(stream_interactor, (!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);
            Dino.MessageProcessor.start(stream_interactor, (!) db);
            Dino.EntityInfo.start(stream_interactor, (!) db);
            Dino.RosterManager.start(stream_interactor, (!) db);
            Dino.Calls.start(stream_interactor, (!) db);
            Dino.ConversationManager.start(stream_interactor, (!) db);
            Dino.PresenceManager.start(stream_interactor, (!) db);
            Dino.MucManager.start(stream_interactor);

            var file_encryption = new Dino.Security.FileEncryption("incoming-jingle-s5b-provider-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            Xmpp.Jid bob_bare_jid = new Xmpp.Jid("bob@example.test");
            seed_trusted_roster_contact((!) db, account, bob_bare_jid);

            var conversation = new Dino.Entities.Conversation(bob_bare_jid, account, Dino.Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);

            stream_interactor.module_manager.initialize(account);
            var stream = new FileManagerJingleTestXmppStream(new Xmpp.Jid("example.test"));
            attach_jingle_s5b_modules_for_tests(stream_interactor, account, stream);
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);
            stream_interactor.account_added(account);

            Dino.Entities.FileTransfer? published_transfer = null;
            Dino.Entities.Conversation? published_conversation = null;
            var publish_loop = new MainLoop();
            uint publish_timeout = 0;
            received_handler = ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                published_conversation = received_conversation;
                if (publish_timeout != 0) {
                    Source.remove(publish_timeout);
                    publish_timeout = 0;
                }
                publish_loop.quit();
            });

            uint8[] payload = "incoming jingle s5b provider payload\n".data;
            Xmpp.Jid peer = new Xmpp.Jid("bob@example.test/phone");
            string jingle_sid = "libdino-incoming-s5b-provider";
            string s5b_sid = "incoming-s5b-session";
            string content_name = "incoming-file";
            StanzaNode iq = build_incoming_jingle_s5b_iq(peer, jingle_sid, content_name, s5b_sid, incoming_file_name, payload.length);
            run_jingle_iq_set(stream, iq);
            if (published_transfer == null) {
                publish_timeout = Timeout.add(5000, () => {
                    publish_timeout = 0;
                    publish_loop.quit();
                    return Source.REMOVE;
                });
                publish_loop.run();
            }
            if (publish_timeout != 0) {
                Source.remove(publish_timeout);
                publish_timeout = 0;
            }
            fail_if(published_transfer == null,
                "incoming Jingle S5B provider must publish the received file transfer shell");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(published_conversation == null || ((!) published_conversation).id != conversation.id,
                "incoming Jingle S5B provider must publish the one-to-one conversation");

            fail_if(!wait_for_written_jingle_action(stream, jingle_sid, "session-accept", 5000),
                "incoming Jingle S5B provider auto-download must accept the transfer");
            StanzaNode accept_jingle = require_written_jingle_action(stream, jingle_sid, "session-accept");
            StanzaNode accept_content = get_required_subnode(accept_jingle, "content", "urn:xmpp:jingle:1");
            StanzaNode accept_transport = get_required_subnode(accept_content, "transport", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns);
            fail_if(accept_transport.get_attribute("sid") != s5b_sid,
                "incoming Jingle S5B provider auto-download must keep the transport SID");
            string? dstaddr = accept_transport.get_attribute("dstaddr");
            fail_if(dstaddr == null || ((!) dstaddr) == "",
                "incoming Jingle S5B provider auto-download must publish dstaddr");
            assert_only_s5b_candidate_type(accept_transport, "direct");
            StanzaNode candidate_node = get_single_candidate_by_type(accept_transport, "direct");
            var local_candidate = Xmpp.Xep.JingleSocks5Bytestreams.Candidate.parse(candidate_node);
            fail_if(local_candidate.jid.to_string() != stream.get_flag(Xmpp.Bind.Flag.IDENTITY).my_jid.to_string(),
                "incoming Jingle S5B provider auto-download must publish the bound full JID on the local candidate");

            peer_connection = run_connect_to_socks5(local_candidate, (!) dstaddr);
            drain_s5b_listener_bookkeeping();
            run_jingle_iq_set(stream,
                build_s5b_candidate_used_transport_info(peer, jingle_sid, content_name, s5b_sid, local_candidate.cid, "libdino-s5b-candidate-used"));
            run_write_all_stream(((!) peer_connection).output_stream, payload);

            fail_if(!wait_for_transfer_phase(file_transfer, Dino.Entities.FileTransfer.Phase.COMPLETE, 5000),
                "incoming Jingle S5B provider auto-download must reach COMPLETE");
            stored_path = file_transfer.path;

            fail_if(file_transfer.id == -1, "incoming Jingle S5B provider transfer must be persisted");
            fail_if(file_transfer.provider != 1, "incoming Jingle S5B provider transfer must keep the Jingle provider id");
            fail_if(file_transfer.direction != Dino.Entities.FileTransfer.DIRECTION_RECEIVED,
                "incoming Jingle S5B provider transfer must be received");
            fail_if(!file_transfer.counterpart.equals_bare(bob_bare_jid),
                "incoming Jingle S5B provider transfer must keep the sender as counterpart");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "incoming Jingle S5B provider transfer must persist complete state in memory");
            fail_if(file_transfer.size != payload.length,
                "incoming Jingle S5B provider transfer must publish the verified plaintext size");
            fail_if(file_transfer.path == null, "incoming Jingle S5B provider transfer must publish a storage path");
            fail_if(!file_transfer.is_plaintext_release_allowed(),
                "incoming Jingle S5B provider transfer must allow plaintext release only after completion");
            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "incoming Jingle S5B provider auto-download must persist COMPLETE state");

            Qlite.RowOption row = ((!) db).file_transfer.select()
                    .with(((!) db).file_transfer.id, "=", file_transfer.id)
                    .single()
                    .row();
            fail_if(!row.is_present(), "incoming Jingle S5B provider transfer must have a database row");
            string? persisted_path = ((!) row.inner)[((!) db).file_transfer.path];
            int64 persisted_size = ((!) row.inner)[((!) db).file_transfer.size];
            fail_if(persisted_path == null || ((!) persisted_path) == "",
                "incoming Jingle S5B provider auto-download must persist the storage path");
            fail_if(persisted_size != payload.length,
                "incoming Jingle S5B provider auto-download must persist the plaintext size");

            File? stored_file = file_transfer.get_file();
            fail_if(stored_file == null || !((!) stored_file).query_exists(),
                "incoming Jingle S5B provider auto-download must write the verified local file");
            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal(payload, decrypted),
                "incoming Jingle S5B provider auto-download must persist the original S5B payload");
            fail_if(count_receive_pending_files_for_basename(Dino.FileManager.get_storage_dir(), incoming_file_name) != 0,
                "incoming Jingle S5B provider auto-download must not leave pending receive files");
            assert_last_session_terminate_reason(stream, jingle_sid, peer, "success");
            assert_no_jingle_session_state(stream, jingle_sid);
        } catch (Error e) {
            fail_if_reached(@"Incoming Jingle S5B provider auto-download test failed: $(e.message)");
        } finally {
            if (peer_connection != null) {
                try { ((!) peer_connection).close(); } catch (Error e) {}
            }
            if (received_handler != 0 && manager != null) {
                ((!) manager).disconnect(received_handler);
            }
            if (db != null) {
                ((!) db).close();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            delete_receive_pending_files_for_basename(Dino.FileManager.get_storage_dir(), incoming_file_name);
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_incoming_jingle_s5b_jet_provider_auto_downloads_receive_store_sync() {
        var loop = new MainLoop();
        test_incoming_jingle_s5b_jet_provider_auto_downloads_receive_store.begin((obj, res) => {
            test_incoming_jingle_s5b_jet_provider_auto_downloads_receive_store.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_incoming_jingle_s5b_jet_provider_auto_downloads_receive_store() {
        try {
            yield run_incoming_jingle_s5b_jet_receive_store(false);
        } catch (Error e) {
            fail_if_reached(@"Incoming Jingle S5B JET provider auto-download test failed: $(e.message)");
        }
    }

    void test_incoming_jingle_s5b_jet_auth_failure_keeps_transfer_unpublished_sync() {
        var loop = new MainLoop();
        test_incoming_jingle_s5b_jet_auth_failure_keeps_transfer_unpublished.begin((obj, res) => {
            test_incoming_jingle_s5b_jet_auth_failure_keeps_transfer_unpublished.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_incoming_jingle_s5b_jet_auth_failure_keeps_transfer_unpublished() {
        try {
            yield run_incoming_jingle_s5b_jet_receive_store(true);
        } catch (Error e) {
            fail_if_reached(@"Incoming Jingle S5B JET auth-failure cleanup test failed: $(e.message)");
        }
    }

    private async void run_incoming_jingle_s5b_jet_receive_store(bool auth_failure) throws Error {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string incoming_file_name = "incoming-s5b-jet-provider-" + Uuid.string_random() + ".txt";
        Dino.Database? db = null;
        string? stored_path = null;
        ulong received_handler = 0;
        Dino.FileManager? manager = null;
        SocketConnection? peer_connection = null;
        Dino.JingleFileEncryptionHelper? previous_jingle_encryption_helper = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, auth_failure ? "incoming-jingle-s5b-jet-auth-failure-test" : "incoming-jingle-s5b-jet-provider-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.MessageStorage.start(stream_interactor, (!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);
            Dino.MessageProcessor.start(stream_interactor, (!) db);
            Dino.EntityInfo.start(stream_interactor, (!) db);
            Dino.RosterManager.start(stream_interactor, (!) db);
            Dino.Calls.start(stream_interactor, (!) db);
            Dino.ConversationManager.start(stream_interactor, (!) db);
            Dino.PresenceManager.start(stream_interactor, (!) db);
            Dino.MucManager.start(stream_interactor);

            var file_encryption = new Dino.Security.FileEncryption(auth_failure ? "incoming-jingle-s5b-jet-auth-failure-test" : "incoming-jingle-s5b-jet-provider-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            Xmpp.Jid bob_bare_jid = new Xmpp.Jid("bob@example.test");
            seed_trusted_roster_contact((!) db, account, bob_bare_jid);

            var conversation = new Dino.Entities.Conversation(bob_bare_jid, account, Dino.Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);

            stream_interactor.module_manager.initialize(account);
            var stream = new FileManagerJingleTestXmppStream(new Xmpp.Jid("example.test"));
            attach_jingle_s5b_modules_for_tests(stream_interactor, account, stream);
            attach_test_jet_security_for_tests(stream);
            previous_jingle_encryption_helper = register_test_jingle_file_encryption_helper();
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);
            stream_interactor.account_added(account);

            Dino.Entities.FileTransfer? published_transfer = null;
            Dino.Entities.Conversation? published_conversation = null;
            var publish_loop = new MainLoop();
            uint publish_timeout = 0;
            received_handler = ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                published_conversation = received_conversation;
                if (publish_timeout != 0) {
                    Source.remove(publish_timeout);
                    publish_timeout = 0;
                }
                publish_loop.quit();
            });

            uint8[] payload = "incoming jingle s5b jet provider payload\n".data;
            uint8[] encrypted_payload = xor_payload(payload, FileManagerTestJetCipher.KEY);
            fail_if(bytes_equal(encrypted_payload, payload),
                "test JET S5B provider payload must be encrypted before entering the S5B socket");
            uint8 expected_tag = test_plaintext_tag(payload);
            if (auth_failure) {
                expected_tag = (uint8) (expected_tag ^ 0x01);
            }
            Xmpp.Jid peer = new Xmpp.Jid("bob@example.test/phone");
            string jingle_sid = auth_failure ? "libdino-incoming-s5b-jet-auth-failure" : "libdino-incoming-s5b-jet-provider";
            string s5b_sid = auth_failure ? "incoming-s5b-jet-auth-failure-session" : "incoming-s5b-jet-session";
            string content_name = "incoming-file";
            StanzaNode iq = build_incoming_jingle_s5b_iq(peer, jingle_sid, content_name, s5b_sid,
                incoming_file_name, payload.length, build_test_jet_security_node(expected_tag));
            FileManagerTestJetCipher.reset_authentication();
            run_jingle_iq_set(stream, iq);
            if (published_transfer == null) {
                publish_timeout = Timeout.add(5000, () => {
                    publish_timeout = 0;
                    publish_loop.quit();
                    return Source.REMOVE;
                });
                publish_loop.run();
            }
            if (publish_timeout != 0) {
                Source.remove(publish_timeout);
                publish_timeout = 0;
            }
            fail_if(published_transfer == null,
                "incoming Jingle S5B JET provider must publish the received file transfer shell");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(published_conversation == null || ((!) published_conversation).id != conversation.id,
                "incoming Jingle S5B JET provider must publish the one-to-one conversation");
            fail_if(file_transfer.encryption != Dino.Entities.Encryption.OMEMO,
                "incoming Jingle S5B JET provider must classify the transfer as OMEMO encrypted");
            fail_if(file_transfer.provider != 1,
                "incoming Jingle S5B JET provider transfer must keep the Jingle provider id");

            if (auth_failure) {
                file_transfer.notify["phase"].connect(() => {
                    fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.PREVIEWING,
                        "JET auth failure must not expose PREVIEWING");
                    fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                        "JET auth failure must not expose COMPLETE");
                });
                GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING,
                    "*Error downloading file: test JET authentication failed*");
            }

            fail_if(!wait_for_written_jingle_action(stream, jingle_sid, "session-accept", 5000),
                "incoming Jingle S5B JET provider auto-download must accept the transfer");
            StanzaNode accept_jingle = require_written_jingle_action(stream, jingle_sid, "session-accept");
            StanzaNode accept_content = get_required_subnode(accept_jingle, "content", "urn:xmpp:jingle:1");
            StanzaNode accept_transport = get_required_subnode(accept_content, "transport", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns);
            fail_if(accept_transport.get_attribute("sid") != s5b_sid,
                "incoming Jingle S5B JET provider auto-download must keep the transport SID");
            string? dstaddr = accept_transport.get_attribute("dstaddr");
            fail_if(dstaddr == null || ((!) dstaddr) == "",
                "incoming Jingle S5B JET provider auto-download must publish dstaddr");
            assert_only_s5b_candidate_type(accept_transport, "direct");
            StanzaNode candidate_node = get_single_candidate_by_type(accept_transport, "direct");
            var local_candidate = Xmpp.Xep.JingleSocks5Bytestreams.Candidate.parse(candidate_node);

            peer_connection = run_connect_to_socks5(local_candidate, (!) dstaddr);
            drain_s5b_listener_bookkeeping();
            run_jingle_iq_set(stream,
                build_s5b_candidate_used_transport_info(peer, jingle_sid, content_name, s5b_sid, local_candidate.cid,
                    auth_failure ? "libdino-s5b-jet-auth-failure-candidate-used" : "libdino-s5b-jet-candidate-used"));
            run_write_all_stream(((!) peer_connection).output_stream, encrypted_payload);

            if (auth_failure) {
                fail_if(!wait_for_transfer_phase(file_transfer, Dino.Entities.FileTransfer.Phase.FAILED, 5000),
                    "incoming Jingle S5B JET auth failure must fail before publish");
                GLib.Test.assert_expected_messages();
                fail_if(!FileManagerTestJetCipher.input_authentication_attempted,
                    "incoming Jingle S5B JET auth failure must attempt stream authentication");
                fail_if(FileManagerTestJetCipher.input_authenticated,
                    "incoming Jingle S5B JET auth failure must not mark the stream authenticated");
                fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                    "incoming Jingle S5B JET auth failure must persist failed state in memory");
                fail_if(file_transfer.path != null,
                    "incoming Jingle S5B JET auth failure must not publish a storage path");
                fail_if(file_transfer.is_plaintext_release_allowed(),
                    "incoming Jingle S5B JET auth failure must not allow plaintext release");
                assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.FAILED,
                    "incoming Jingle S5B JET auth failure must persist FAILED state");
                Qlite.RowOption failed_row = ((!) db).file_transfer.select()
                        .with(((!) db).file_transfer.id, "=", file_transfer.id)
                        .single()
                        .row();
                fail_if(!failed_row.is_present(),
                    "incoming Jingle S5B JET auth failure must keep the transfer row for auditability");
                string? persisted_failed_path = ((!) failed_row.inner)[((!) db).file_transfer.path];
                fail_if(persisted_failed_path != null && ((!) persisted_failed_path) != "",
                    "incoming Jingle S5B JET auth failure must not persist a storage path");
                fail_if(count_receive_pending_files_for_basename(Dino.FileManager.get_storage_dir(), incoming_file_name) != 0,
                    "incoming Jingle S5B JET auth failure must delete pending receive files");
                fail_if(!wait_for_written_jingle_action(stream, jingle_sid, "session-terminate", 5000),
                    "incoming Jingle S5B JET auth failure must terminate the Jingle session");
                assert_last_session_terminate_reason(stream, jingle_sid, peer, "failed-transport");
                assert_no_jingle_session_state(stream, jingle_sid);
                return;
            }

            fail_if(!wait_for_transfer_phase(file_transfer, Dino.Entities.FileTransfer.Phase.COMPLETE, 5000),
                "incoming Jingle S5B JET provider auto-download must reach COMPLETE");
            stored_path = file_transfer.path;

            fail_if(!FileManagerTestJetCipher.input_authenticated,
                "incoming Jingle S5B JET provider must authenticate the stream before completion");
            fail_if(file_transfer.id == -1, "incoming Jingle S5B JET provider transfer must be persisted");
            fail_if(file_transfer.direction != Dino.Entities.FileTransfer.DIRECTION_RECEIVED,
                "incoming Jingle S5B JET provider transfer must be received");
            fail_if(!file_transfer.counterpart.equals_bare(bob_bare_jid),
                "incoming Jingle S5B JET provider transfer must keep the sender as counterpart");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "incoming Jingle S5B JET provider transfer must persist complete state in memory");
            fail_if(file_transfer.size != payload.length,
                "incoming Jingle S5B JET provider transfer must publish the verified plaintext size");
            fail_if(file_transfer.path == null, "incoming Jingle S5B JET provider transfer must publish a storage path");
            fail_if(!file_transfer.is_plaintext_release_allowed(),
                "incoming Jingle S5B JET provider transfer must allow plaintext release only after completion");
            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "incoming Jingle S5B JET provider auto-download must persist COMPLETE state");

            Qlite.RowOption row = ((!) db).file_transfer.select()
                    .with(((!) db).file_transfer.id, "=", file_transfer.id)
                    .single()
                    .row();
            fail_if(!row.is_present(), "incoming Jingle S5B JET provider transfer must have a database row");
            string? persisted_path = ((!) row.inner)[((!) db).file_transfer.path];
            int64 persisted_size = ((!) row.inner)[((!) db).file_transfer.size];
            fail_if(persisted_path == null || ((!) persisted_path) == "",
                "incoming Jingle S5B JET provider auto-download must persist the storage path");
            fail_if(persisted_size != payload.length,
                "incoming Jingle S5B JET provider auto-download must persist the plaintext size");

            File? stored_file = file_transfer.get_file();
            fail_if(stored_file == null || !((!) stored_file).query_exists(),
                "incoming Jingle S5B JET provider auto-download must write the verified local file");
            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal(payload, decrypted),
                "incoming Jingle S5B JET provider auto-download must persist the decrypted S5B payload");
            fail_if(count_receive_pending_files_for_basename(Dino.FileManager.get_storage_dir(), incoming_file_name) != 0,
                "incoming Jingle S5B JET provider auto-download must not leave pending receive files");
            assert_last_session_terminate_reason(stream, jingle_sid, peer, "success");
            assert_no_jingle_session_state(stream, jingle_sid);
        } finally {
            if (peer_connection != null) {
                try { ((!) peer_connection).close(); } catch (Error e) {}
            }
            if (received_handler != 0 && manager != null) {
                ((!) manager).disconnect(received_handler);
            }
            restore_test_jingle_file_encryption_helper(previous_jingle_encryption_helper);
            if (db != null) {
                ((!) db).close();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            delete_receive_pending_files_for_basename(Dino.FileManager.get_storage_dir(), incoming_file_name);
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_incoming_jingle_s5b_account_proxy_activation_auto_downloads_receive_store_sync() {
        var loop = new MainLoop();
        test_incoming_jingle_s5b_account_proxy_activation_auto_downloads_receive_store.begin((obj, res) => {
            test_incoming_jingle_s5b_account_proxy_activation_auto_downloads_receive_store.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_incoming_jingle_s5b_account_proxy_activation_auto_downloads_receive_store() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string incoming_file_name = "incoming-s5b-account-proxy-activation-provider-" + Uuid.string_random() + ".txt";
        Dino.Database? db = null;
        string? stored_path = null;
        ulong received_handler = 0;
        Dino.FileManager? manager = null;
        FileManagerFakeOutboundSocksProxy? outbound_proxy = null;
        FileManagerDirectConnectTrap? direct_trap = null;
        try {
            outbound_proxy = new FileManagerFakeOutboundSocksProxy();
            direct_trap = new FileManagerDirectConnectTrap();

            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "incoming-jingle-s5b-account-proxy-activation-provider-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.MessageStorage.start(stream_interactor, (!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);
            Dino.MessageProcessor.start(stream_interactor, (!) db);
            Dino.EntityInfo.start(stream_interactor, (!) db);
            Dino.RosterManager.start(stream_interactor, (!) db);
            Dino.Calls.start(stream_interactor, (!) db);
            Dino.ConversationManager.start(stream_interactor, (!) db);
            Dino.PresenceManager.start(stream_interactor, (!) db);
            Dino.MucManager.start(stream_interactor);

            var file_encryption = new Dino.Security.FileEncryption("incoming-jingle-s5b-account-proxy-activation-provider-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            Xmpp.Jid bob_bare_jid = new Xmpp.Jid("bob@example.test");
            seed_trusted_roster_contact((!) db, account, bob_bare_jid);

            var conversation = new Dino.Entities.Conversation(bob_bare_jid, account, Dino.Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);

            stream_interactor.module_manager.initialize(account);
            var stream = new FileManagerJingleTestXmppStream(new Xmpp.Jid("example.test"));
            attach_jingle_s5b_modules_for_tests(stream_interactor, account, stream);
            var jingle_s5b = stream.get_module<Xmpp.Xep.JingleSocks5Bytestreams.Module>(Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY);
            fail_if(jingle_s5b == null, "test setup must attach the Jingle S5B module");
            ((!) jingle_s5b).set_network_policy(false, "socks5://127.0.0.1:%d".printf(((!) outbound_proxy).port));
            Xmpp.Jid proxy_jid = new Xmpp.Jid("proxy.example.test");
            add_s5b_proxy(stream, "127.0.0.1", proxy_jid, ((!) direct_trap).port);
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);
            stream_interactor.account_added(account);

            Dino.Entities.FileTransfer? published_transfer = null;
            Dino.Entities.Conversation? published_conversation = null;
            var publish_loop = new MainLoop();
            uint publish_timeout = 0;
            received_handler = ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                published_conversation = received_conversation;
                if (publish_timeout != 0) {
                    Source.remove(publish_timeout);
                    publish_timeout = 0;
                }
                publish_loop.quit();
            });

            uint8[] payload = "incoming jingle s5b account proxy activation provider payload\n".data;
            Xmpp.Jid peer = new Xmpp.Jid("bob@example.test/phone");
            string jingle_sid = "libdino-incoming-s5b-account-proxy-activation-provider";
            string s5b_sid = "incoming-s5b-account-proxy-activation-session";
            string content_name = "incoming-file";

            StanzaNode iq = build_incoming_jingle_s5b_iq(peer, jingle_sid, content_name, s5b_sid, incoming_file_name, payload.length);
            run_jingle_iq_set(stream, iq);
            if (published_transfer == null) {
                publish_timeout = Timeout.add(5000, () => {
                    publish_timeout = 0;
                    publish_loop.quit();
                    return Source.REMOVE;
                });
                publish_loop.run();
            }
            if (publish_timeout != 0) {
                Source.remove(publish_timeout);
                publish_timeout = 0;
            }
            fail_if(published_transfer == null,
                "incoming Jingle S5B account-proxy activation provider must publish the received file transfer shell");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(published_conversation == null || ((!) published_conversation).id != conversation.id,
                "incoming Jingle S5B account-proxy activation provider must publish the one-to-one conversation");

            fail_if(!wait_for_written_jingle_action(stream, jingle_sid, "session-accept", 5000),
                "incoming Jingle S5B account-proxy activation provider auto-download must accept the transfer");
            StanzaNode accept_jingle = require_written_jingle_action(stream, jingle_sid, "session-accept");
            StanzaNode accept_content = get_required_subnode(accept_jingle, "content", "urn:xmpp:jingle:1");
            StanzaNode accept_transport = get_required_subnode(accept_content, "transport", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns);
            fail_if(accept_transport.get_attribute("sid") != s5b_sid,
                "incoming Jingle S5B account-proxy activation provider auto-download must keep the transport SID");
            string? dstaddr = accept_transport.get_attribute("dstaddr");
            fail_if(dstaddr == null || ((!) dstaddr) == "",
                "incoming Jingle S5B account-proxy activation provider auto-download must publish dstaddr");
            assert_only_s5b_candidate_type(accept_transport, "proxy");
            StanzaNode proxy_candidate_node = get_single_candidate_by_type(accept_transport, "proxy");
            var proxy_candidate = Xmpp.Xep.JingleSocks5Bytestreams.Candidate.parse(proxy_candidate_node);
            fail_if(proxy_candidate.host != "127.0.0.1",
                "incoming Jingle S5B account-proxy activation provider auto-download must publish the discovered proxy host");
            fail_if(proxy_candidate.jid.to_string() != proxy_jid.to_string(),
                "incoming Jingle S5B account-proxy activation provider auto-download must publish the discovered proxy JID");
            fail_if(proxy_candidate.port != ((!) direct_trap).port,
                "incoming Jingle S5B account-proxy activation provider auto-download must publish the discovered proxy port");
            ((!) outbound_proxy).expect(proxy_candidate.host, proxy_candidate.port, (!) dstaddr);

            run_jingle_iq_set(stream,
                build_s5b_candidate_used_transport_info(peer, jingle_sid, content_name, s5b_sid, proxy_candidate.cid, "libdino-s5b-account-proxy-activation-candidate-used"));
            fail_if(!wait_for_written_socks5_activation_iq(stream, s5b_sid, proxy_jid, peer, 5000),
                "incoming Jingle S5B account-proxy activation provider auto-download must request proxy activation");
            ((!) outbound_proxy).wait_until_connected(5000);
            StanzaNode activation_iq = require_written_socks5_activation_iq(stream, s5b_sid, proxy_jid, peer);
            stream.emit_iq_result(build_iq_result(activation_iq, proxy_jid, account.full_jid));
            fail_if(!wait_for_written_s5b_transport_info_child(stream, jingle_sid, content_name, s5b_sid,
                    "activated", proxy_candidate.cid, 5000),
                "incoming Jingle S5B account-proxy activation provider auto-download must announce proxy activation");
            fail_if(((!) outbound_proxy).connection == null,
                "incoming Jingle S5B account-proxy activation provider auto-download must expose the activated proxy connection");
            SocketConnection proxy_connection = (!) ((!) outbound_proxy).connection;
            run_write_all_stream(proxy_connection.output_stream, payload);

            fail_if(!wait_for_transfer_phase(file_transfer, Dino.Entities.FileTransfer.Phase.COMPLETE, 5000),
                "incoming Jingle S5B account-proxy activation provider auto-download must reach COMPLETE");
            stored_path = file_transfer.path;

            ((!) direct_trap).assert_not_hit_after(100);
            fail_if(file_transfer.id == -1, "incoming Jingle S5B account-proxy activation provider transfer must be persisted");
            fail_if(file_transfer.provider != 1, "incoming Jingle S5B account-proxy activation provider transfer must keep the Jingle provider id");
            fail_if(file_transfer.direction != Dino.Entities.FileTransfer.DIRECTION_RECEIVED,
                "incoming Jingle S5B account-proxy activation provider transfer must be received");
            fail_if(!file_transfer.counterpart.equals_bare(bob_bare_jid),
                "incoming Jingle S5B account-proxy activation provider transfer must keep the sender as counterpart");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "incoming Jingle S5B account-proxy activation provider transfer must persist complete state in memory");
            fail_if(file_transfer.size != payload.length,
                "incoming Jingle S5B account-proxy activation provider transfer must publish the verified plaintext size");
            fail_if(file_transfer.path == null, "incoming Jingle S5B account-proxy activation provider transfer must publish a storage path");
            fail_if(!file_transfer.is_plaintext_release_allowed(),
                "incoming Jingle S5B account-proxy activation provider transfer must allow plaintext release only after completion");
            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "incoming Jingle S5B account-proxy activation provider auto-download must persist COMPLETE state");

            Qlite.RowOption row = ((!) db).file_transfer.select()
                    .with(((!) db).file_transfer.id, "=", file_transfer.id)
                    .single()
                    .row();
            fail_if(!row.is_present(), "incoming Jingle S5B account-proxy activation provider transfer must have a database row");
            string? persisted_path = ((!) row.inner)[((!) db).file_transfer.path];
            int64 persisted_size = ((!) row.inner)[((!) db).file_transfer.size];
            fail_if(persisted_path == null || ((!) persisted_path) == "",
                "incoming Jingle S5B account-proxy activation provider auto-download must persist the storage path");
            fail_if(persisted_size != payload.length,
                "incoming Jingle S5B account-proxy activation provider auto-download must persist the plaintext size");

            File? stored_file = file_transfer.get_file();
            fail_if(stored_file == null || !((!) stored_file).query_exists(),
                "incoming Jingle S5B account-proxy activation provider auto-download must write the verified local file");
            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal(payload, decrypted),
                "incoming Jingle S5B account-proxy activation provider auto-download must persist the original S5B payload");
            fail_if(count_receive_pending_files_for_basename(Dino.FileManager.get_storage_dir(), incoming_file_name) != 0,
                "incoming Jingle S5B account-proxy activation provider auto-download must not leave pending receive files");
            assert_last_session_terminate_reason(stream, jingle_sid, peer, "success");
            assert_no_jingle_session_state(stream, jingle_sid);
        } catch (Error e) {
            fail_if_reached(@"Incoming Jingle S5B account-proxy activation provider auto-download test failed: $(e.message)");
        } finally {
            if (received_handler != 0 && manager != null) {
                ((!) manager).disconnect(received_handler);
            }
            if (outbound_proxy != null) {
                ((!) outbound_proxy).close();
            }
            if (direct_trap != null) {
                ((!) direct_trap).close();
            }
            if (db != null) {
                ((!) db).close();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            delete_receive_pending_files_for_basename(Dino.FileManager.get_storage_dir(), incoming_file_name);
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_incoming_jingle_s5b_account_proxy_auto_downloads_receive_store_sync() {
        var loop = new MainLoop();
        test_incoming_jingle_s5b_account_proxy_auto_downloads_receive_store.begin((obj, res) => {
            test_incoming_jingle_s5b_account_proxy_auto_downloads_receive_store.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_incoming_jingle_s5b_account_proxy_auto_downloads_receive_store() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string incoming_file_name = "incoming-s5b-account-proxy-provider-" + Uuid.string_random() + ".txt";
        Dino.Database? db = null;
        string? stored_path = null;
        ulong received_handler = 0;
        Dino.FileManager? manager = null;
        FileManagerFakeOutboundSocksProxy? outbound_proxy = null;
        FileManagerDirectConnectTrap? direct_trap = null;
        try {
            outbound_proxy = new FileManagerFakeOutboundSocksProxy();
            direct_trap = new FileManagerDirectConnectTrap();

            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "incoming-jingle-s5b-account-proxy-provider-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.MessageStorage.start(stream_interactor, (!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);
            Dino.MessageProcessor.start(stream_interactor, (!) db);
            Dino.EntityInfo.start(stream_interactor, (!) db);
            Dino.RosterManager.start(stream_interactor, (!) db);
            Dino.Calls.start(stream_interactor, (!) db);
            Dino.ConversationManager.start(stream_interactor, (!) db);
            Dino.PresenceManager.start(stream_interactor, (!) db);
            Dino.MucManager.start(stream_interactor);

            var file_encryption = new Dino.Security.FileEncryption("incoming-jingle-s5b-account-proxy-provider-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            Xmpp.Jid bob_bare_jid = new Xmpp.Jid("bob@example.test");
            seed_trusted_roster_contact((!) db, account, bob_bare_jid);

            var conversation = new Dino.Entities.Conversation(bob_bare_jid, account, Dino.Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);

            stream_interactor.module_manager.initialize(account);
            var stream = new FileManagerJingleTestXmppStream(new Xmpp.Jid("example.test"));
            attach_jingle_s5b_modules_for_tests(stream_interactor, account, stream);
            var jingle_s5b = stream.get_module<Xmpp.Xep.JingleSocks5Bytestreams.Module>(Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY);
            fail_if(jingle_s5b == null, "test setup must attach the Jingle S5B module");
            ((!) jingle_s5b).set_network_policy(false, "socks5://127.0.0.1:%d".printf(((!) outbound_proxy).port));
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);
            stream_interactor.account_added(account);

            Dino.Entities.FileTransfer? published_transfer = null;
            Dino.Entities.Conversation? published_conversation = null;
            var publish_loop = new MainLoop();
            uint publish_timeout = 0;
            received_handler = ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                published_conversation = received_conversation;
                if (publish_timeout != 0) {
                    Source.remove(publish_timeout);
                    publish_timeout = 0;
                }
                publish_loop.quit();
            });

            uint8[] payload = "incoming jingle s5b account proxy provider payload\n".data;
            Xmpp.Jid peer = new Xmpp.Jid("bob@example.test/phone");
            string jingle_sid = "libdino-incoming-s5b-account-proxy-provider";
            string s5b_sid = "incoming-s5b-account-proxy-session";
            string content_name = "incoming-file";
            string remote_candidate_cid = "peer-direct-candidate";
            string remote_candidate_host = "127.0.0.1";
            int remote_candidate_port = ((!) direct_trap).port;
            string remote_dstaddr = Xmpp.Xep.JingleSocks5Bytestreams.calculate_dstaddr(s5b_sid, peer, account.full_jid);
            ((!) outbound_proxy).expect(remote_candidate_host, remote_candidate_port, remote_dstaddr);

            StanzaNode iq = build_incoming_jingle_s5b_iq_with_candidate(account.full_jid, peer, jingle_sid, content_name, s5b_sid,
                incoming_file_name, payload.length, remote_candidate_cid, remote_candidate_host, remote_candidate_port);
            run_jingle_iq_set(stream, iq);
            if (published_transfer == null) {
                publish_timeout = Timeout.add(5000, () => {
                    publish_timeout = 0;
                    publish_loop.quit();
                    return Source.REMOVE;
                });
                publish_loop.run();
            }
            if (publish_timeout != 0) {
                Source.remove(publish_timeout);
                publish_timeout = 0;
            }
            fail_if(published_transfer == null,
                "incoming Jingle S5B account-proxy provider must publish the received file transfer shell");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(published_conversation == null || ((!) published_conversation).id != conversation.id,
                "incoming Jingle S5B account-proxy provider must publish the one-to-one conversation");

            fail_if(!wait_for_written_jingle_action(stream, jingle_sid, "session-accept", 5000),
                "incoming Jingle S5B account-proxy provider auto-download must accept the transfer");
            StanzaNode accept_jingle = require_written_jingle_action(stream, jingle_sid, "session-accept");
            StanzaNode accept_content = get_required_subnode(accept_jingle, "content", "urn:xmpp:jingle:1");
            StanzaNode accept_transport = get_required_subnode(accept_content, "transport", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns);
            fail_if(accept_transport.get_attribute("sid") != s5b_sid,
                "incoming Jingle S5B account-proxy provider auto-download must keep the transport SID");
            fail_if(accept_transport.get_subnodes("candidate", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns).size != 0,
                "incoming Jingle S5B account-proxy provider auto-download must not publish local candidates");

            ((!) outbound_proxy).wait_until_connected(5000);
            fail_if(!wait_for_written_s5b_transport_info_child(stream, jingle_sid, content_name, s5b_sid,
                    "candidate-used", remote_candidate_cid, 5000),
                "incoming Jingle S5B account-proxy provider auto-download must select the remote candidate through the account proxy");
            run_jingle_iq_set(stream,
                build_s5b_candidate_error_transport_info(account.full_jid, peer, jingle_sid, content_name, s5b_sid, "libdino-s5b-account-proxy-candidate-error"));
            fail_if(((!) outbound_proxy).connection == null,
                "incoming Jingle S5B account-proxy provider auto-download must expose the proxied S5B connection");
            SocketConnection proxy_connection = (!) ((!) outbound_proxy).connection;
            run_write_all_stream(proxy_connection.output_stream, payload);

            fail_if(!wait_for_transfer_phase(file_transfer, Dino.Entities.FileTransfer.Phase.COMPLETE, 5000),
                "incoming Jingle S5B account-proxy provider auto-download must reach COMPLETE");
            stored_path = file_transfer.path;

            ((!) direct_trap).assert_not_hit_after(100);
            fail_if(file_transfer.id == -1, "incoming Jingle S5B account-proxy provider transfer must be persisted");
            fail_if(file_transfer.provider != 1, "incoming Jingle S5B account-proxy provider transfer must keep the Jingle provider id");
            fail_if(file_transfer.direction != Dino.Entities.FileTransfer.DIRECTION_RECEIVED,
                "incoming Jingle S5B account-proxy provider transfer must be received");
            fail_if(!file_transfer.counterpart.equals_bare(bob_bare_jid),
                "incoming Jingle S5B account-proxy provider transfer must keep the sender as counterpart");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "incoming Jingle S5B account-proxy provider transfer must persist complete state in memory");
            fail_if(file_transfer.size != payload.length,
                "incoming Jingle S5B account-proxy provider transfer must publish the verified plaintext size");
            fail_if(file_transfer.path == null, "incoming Jingle S5B account-proxy provider transfer must publish a storage path");
            fail_if(!file_transfer.is_plaintext_release_allowed(),
                "incoming Jingle S5B account-proxy provider transfer must allow plaintext release only after completion");
            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "incoming Jingle S5B account-proxy provider auto-download must persist COMPLETE state");

            Qlite.RowOption row = ((!) db).file_transfer.select()
                    .with(((!) db).file_transfer.id, "=", file_transfer.id)
                    .single()
                    .row();
            fail_if(!row.is_present(), "incoming Jingle S5B account-proxy provider transfer must have a database row");
            string? persisted_path = ((!) row.inner)[((!) db).file_transfer.path];
            int64 persisted_size = ((!) row.inner)[((!) db).file_transfer.size];
            fail_if(persisted_path == null || ((!) persisted_path) == "",
                "incoming Jingle S5B account-proxy provider auto-download must persist the storage path");
            fail_if(persisted_size != payload.length,
                "incoming Jingle S5B account-proxy provider auto-download must persist the plaintext size");

            File? stored_file = file_transfer.get_file();
            fail_if(stored_file == null || !((!) stored_file).query_exists(),
                "incoming Jingle S5B account-proxy provider auto-download must write the verified local file");
            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal(payload, decrypted),
                "incoming Jingle S5B account-proxy provider auto-download must persist the original S5B payload");
            fail_if(count_receive_pending_files_for_basename(Dino.FileManager.get_storage_dir(), incoming_file_name) != 0,
                "incoming Jingle S5B account-proxy provider auto-download must not leave pending receive files");
            assert_last_session_terminate_reason(stream, jingle_sid, peer, "success");
            assert_no_jingle_session_state(stream, jingle_sid);
        } catch (Error e) {
            fail_if_reached(@"Incoming Jingle S5B account-proxy provider auto-download test failed: $(e.message)");
        } finally {
            if (received_handler != 0 && manager != null) {
                ((!) manager).disconnect(received_handler);
            }
            if (outbound_proxy != null) {
                ((!) outbound_proxy).close();
            }
            if (direct_trap != null) {
                ((!) direct_trap).close();
            }
            if (db != null) {
                ((!) db).close();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            delete_receive_pending_files_for_basename(Dino.FileManager.get_storage_dir(), incoming_file_name);
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_incoming_jingle_s5b_real_tor_onion_auto_downloads_receive_store_sync() {
        string? tor_path = FileManagerLocalTorSocksDaemon.lookup_hidden_service_tor_path_or_skip();
        if (tor_path == null) return;

        var loop = new MainLoop();
        test_incoming_jingle_s5b_real_tor_onion_auto_downloads_receive_store.begin((!) tor_path, (obj, res) => {
            test_incoming_jingle_s5b_real_tor_onion_auto_downloads_receive_store.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_incoming_jingle_s5b_real_tor_onion_auto_downloads_receive_store(string tor_path) {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        string incoming_file_name = "incoming-s5b-real-tor-onion-provider-" + Uuid.string_random() + ".txt";
        Dino.Database? db = null;
        string? stored_path = null;
        ulong received_handler = 0;
        Dino.FileManager? manager = null;
        FileManagerHiddenServiceS5BTarget? target = null;
        FileManagerLocalTorSocksDaemon? tor = null;
        try {
            target = new FileManagerHiddenServiceS5BTarget();
            tor = FileManagerLocalTorSocksDaemon.start_hidden_service(tor_path, ((!) target).port, 7777);
            string? onion_hostname = ((!) tor).onion_hostname;
            fail_if(onion_hostname == null || ((!) onion_hostname) == "",
                "FileManager real Tor onion S5B provider test must receive an onion hostname");
            ((!) target).expect_warmup();
            run_connect_to_onion_through_tor((!) tor, (!) onion_hostname, 7777, 180000);
            ((!) target).wait_until_warmup_completed(5000);

            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "incoming-jingle-s5b-real-tor-onion-provider-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.MessageStorage.start(stream_interactor, (!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);
            Dino.MessageProcessor.start(stream_interactor, (!) db);
            Dino.EntityInfo.start(stream_interactor, (!) db);
            Dino.RosterManager.start(stream_interactor, (!) db);
            Dino.Calls.start(stream_interactor, (!) db);
            Dino.ConversationManager.start(stream_interactor, (!) db);
            Dino.PresenceManager.start(stream_interactor, (!) db);
            Dino.MucManager.start(stream_interactor);

            var file_encryption = new Dino.Security.FileEncryption("incoming-jingle-s5b-real-tor-onion-provider-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            Xmpp.Jid bob_bare_jid = new Xmpp.Jid("bob@example.test");
            seed_trusted_roster_contact((!) db, account, bob_bare_jid);

            var conversation = new Dino.Entities.Conversation(bob_bare_jid, account, Dino.Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);

            stream_interactor.module_manager.initialize(account);
            var stream = new FileManagerJingleTestXmppStream(new Xmpp.Jid("example.test"));
            attach_jingle_s5b_modules_for_tests(stream_interactor, account, stream);
            var jingle_s5b = stream.get_module<Xmpp.Xep.JingleSocks5Bytestreams.Module>(Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY);
            fail_if(jingle_s5b == null, "test setup must attach the Jingle S5B module");
            ((!) jingle_s5b).set_network_policy(false, "socks5://127.0.0.1:%d".printf(((!) tor).port));
            stream_interactor.connection_manager.set_connected_stream_for_tests(account, stream);
            stream_interactor.account_added(account);

            Dino.Entities.FileTransfer? published_transfer = null;
            Dino.Entities.Conversation? published_conversation = null;
            var publish_loop = new MainLoop();
            uint publish_timeout = 0;
            received_handler = ((!) manager).received_file.connect((file_transfer, received_conversation) => {
                published_transfer = file_transfer;
                published_conversation = received_conversation;
                if (publish_timeout != 0) {
                    Source.remove(publish_timeout);
                    publish_timeout = 0;
                }
                publish_loop.quit();
            });

            uint8[] payload = "incoming jingle s5b real tor onion provider payload\n".data;
            Xmpp.Jid peer = new Xmpp.Jid("bob@example.test/phone");
            string jingle_sid = "libdino-incoming-s5b-real-tor-onion-provider";
            string s5b_sid = "incoming-s5b-real-tor-onion-session";
            string content_name = "incoming-file";
            string remote_candidate_cid = "peer-onion-candidate";
            int remote_candidate_port = 7777;
            string remote_dstaddr = Xmpp.Xep.JingleSocks5Bytestreams.calculate_dstaddr(s5b_sid, peer, account.full_jid);
            ((!) target).expect(remote_dstaddr);

            StanzaNode iq = build_incoming_jingle_s5b_iq_with_candidate(account.full_jid, peer, jingle_sid, content_name, s5b_sid,
                incoming_file_name, payload.length, remote_candidate_cid, (!) onion_hostname, remote_candidate_port);
            run_jingle_iq_set(stream, iq);
            if (published_transfer == null) {
                publish_timeout = Timeout.add(5000, () => {
                    publish_timeout = 0;
                    publish_loop.quit();
                    return Source.REMOVE;
                });
                publish_loop.run();
            }
            if (publish_timeout != 0) {
                Source.remove(publish_timeout);
                publish_timeout = 0;
            }
            fail_if(published_transfer == null,
                "incoming Jingle S5B real Tor onion provider must publish the received file transfer shell");
            Dino.Entities.FileTransfer file_transfer = (!) published_transfer;
            fail_if(published_conversation == null || ((!) published_conversation).id != conversation.id,
                "incoming Jingle S5B real Tor onion provider must publish the one-to-one conversation");

            fail_if(!wait_for_written_jingle_action(stream, jingle_sid, "session-accept", 5000),
                "incoming Jingle S5B real Tor onion provider auto-download must accept the transfer");
            StanzaNode accept_jingle = require_written_jingle_action(stream, jingle_sid, "session-accept");
            StanzaNode accept_content = get_required_subnode(accept_jingle, "content", "urn:xmpp:jingle:1");
            StanzaNode accept_transport = get_required_subnode(accept_content, "transport", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns);
            fail_if(accept_transport.get_attribute("sid") != s5b_sid,
                "incoming Jingle S5B real Tor onion provider auto-download must keep the transport SID");
            fail_if(accept_transport.get_subnodes("candidate", Xmpp.Xep.JingleSocks5Bytestreams.Module.IDENTITY.ns).size != 0,
                "incoming Jingle S5B real Tor onion provider auto-download must not publish local candidates");

            ((!) target).wait_until_connected(5000);
            fail_if(!wait_for_written_s5b_transport_info_child(stream, jingle_sid, content_name, s5b_sid,
                    "candidate-used", remote_candidate_cid, 5000),
                "incoming Jingle S5B real Tor onion provider auto-download must select the remote onion candidate through Tor");
            run_jingle_iq_set(stream,
                build_s5b_candidate_error_transport_info(account.full_jid, peer, jingle_sid, content_name, s5b_sid, "libdino-s5b-real-tor-onion-candidate-error"));
            fail_if(((!) target).connection == null,
                "incoming Jingle S5B real Tor onion provider auto-download must expose the onion target S5B connection");
            SocketConnection target_connection = (!) ((!) target).connection;
            run_write_all_stream(target_connection.output_stream, payload);

            fail_if(!wait_for_transfer_phase(file_transfer, Dino.Entities.FileTransfer.Phase.COMPLETE, 5000),
                "incoming Jingle S5B real Tor onion provider auto-download must reach COMPLETE");
            stored_path = file_transfer.path;

            fail_if(file_transfer.id == -1, "incoming Jingle S5B real Tor onion provider transfer must be persisted");
            fail_if(file_transfer.provider != 1, "incoming Jingle S5B real Tor onion provider transfer must keep the Jingle provider id");
            fail_if(file_transfer.direction != Dino.Entities.FileTransfer.DIRECTION_RECEIVED,
                "incoming Jingle S5B real Tor onion provider transfer must be received");
            fail_if(!file_transfer.counterpart.equals_bare(bob_bare_jid),
                "incoming Jingle S5B real Tor onion provider transfer must keep the sender as counterpart");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "incoming Jingle S5B real Tor onion provider transfer must persist complete state in memory");
            fail_if(file_transfer.size != payload.length,
                "incoming Jingle S5B real Tor onion provider transfer must publish the verified plaintext size");
            fail_if(file_transfer.path == null, "incoming Jingle S5B real Tor onion provider transfer must publish a storage path");
            fail_if(!file_transfer.is_plaintext_release_allowed(),
                "incoming Jingle S5B real Tor onion provider transfer must allow plaintext release only after completion");
            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "incoming Jingle S5B real Tor onion provider auto-download must persist COMPLETE state");

            Qlite.RowOption row = ((!) db).file_transfer.select()
                    .with(((!) db).file_transfer.id, "=", file_transfer.id)
                    .single()
                    .row();
            fail_if(!row.is_present(), "incoming Jingle S5B real Tor onion provider transfer must have a database row");
            string? persisted_path = ((!) row.inner)[((!) db).file_transfer.path];
            int64 persisted_size = ((!) row.inner)[((!) db).file_transfer.size];
            fail_if(persisted_path == null || ((!) persisted_path) == "",
                "incoming Jingle S5B real Tor onion provider auto-download must persist the storage path");
            fail_if(persisted_size != payload.length,
                "incoming Jingle S5B real Tor onion provider auto-download must persist the plaintext size");

            File? stored_file = file_transfer.get_file();
            fail_if(stored_file == null || !((!) stored_file).query_exists(),
                "incoming Jingle S5B real Tor onion provider auto-download must write the verified local file");
            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal(payload, decrypted),
                "incoming Jingle S5B real Tor onion provider auto-download must persist the original S5B payload");
            fail_if(count_receive_pending_files_for_basename(Dino.FileManager.get_storage_dir(), incoming_file_name) != 0,
                "incoming Jingle S5B real Tor onion provider auto-download must not leave pending receive files");
            assert_last_session_terminate_reason(stream, jingle_sid, peer, "success");
            assert_no_jingle_session_state(stream, jingle_sid);
        } catch (Error e) {
            fail_if_reached(@"Incoming Jingle S5B real Tor onion provider auto-download test failed: $(e.message)");
        } finally {
            if (received_handler != 0 && manager != null) {
                ((!) manager).disconnect(received_handler);
            }
            if (target != null) {
                ((!) target).close();
            }
            if (tor != null) {
                ((!) tor).close();
            }
            if (db != null) {
                ((!) db).close();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            delete_receive_pending_files_for_basename(Dino.FileManager.get_storage_dir(), incoming_file_name);
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_receive_plain_stream_failure_cleans_pending_before_publish_sync() {
        var loop = new MainLoop();
        test_receive_plain_stream_failure_cleans_pending_before_publish.begin((obj, res) => {
            test_receive_plain_stream_failure_cleans_pending_before_publish.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_receive_plain_stream_failure_cleans_pending_before_publish() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var file_encryption = new Dino.Security.FileEncryption("receive-plain-stream-failure-test");
            uint8[] partial_plaintext = "partial provider bytes before failure\n".data;

            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "provider-stream.txt";
            file_transfer.mime_type = "text/plain";
            file_transfer.size = 123456;
            string original_name = file_transfer.file_name;
            string? original_mime_type = file_transfer.mime_type;
            int64 original_size = file_transfer.size;

            bool saw_downloading_phase = false;
            file_transfer.notify["phase"].connect(() => {
                if (file_transfer.phase == Dino.Entities.FileTransfer.Phase.DOWNLOADING) {
                    saw_downloading_phase = true;
                    fail_if(file_transfer.path != null,
                        "plain stream failure must not publish the path while downloading");
                    fail_if(file_transfer.size != original_size,
                        "plain stream failure must not publish plaintext size while downloading");
                    fail_if(file_transfer.is_plaintext_release_allowed(),
                        "plain stream failure must not allow plaintext release while downloading");
                }
                fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.PREVIEWING,
                    "plain stream failure must not expose PREVIEWING");
                fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                    "plain stream failure must not expose COMPLETE");
            });

            bool failed = false;
            try {
                yield Dino.FileManager.store_received_file_for_tests(
                        file_encryption, file_transfer, new TestPartialFailingInputStream(partial_plaintext), temp_dir);
                fail_if_reached("plain receive stream failure must fail before publish");
            } catch (Error e) {
                failed = true;
            }

            fail_if(!failed, "plain receive stream failure must be rejected");
            fail_if(!saw_downloading_phase, "plain receive stream failure must expose DOWNLOADING before rejection");
            fail_if_not_eq_str(file_transfer.file_name, original_name,
                "plain receive stream failure must not change filename");
            fail_if_not_eq_str(file_transfer.mime_type, original_mime_type,
                "plain receive stream failure must not change MIME type");
            fail_if(file_transfer.size != original_size,
                "plain receive stream failure must not publish plaintext size");
            fail_if(file_transfer.path != null,
                "plain receive stream failure must not publish a storage path");
            fail_if(file_transfer.is_plaintext_release_allowed(),
                "plain receive stream failure must not allow plaintext release");
            fail_if(count_directory_entries(temp_dir) != 0,
                "plain receive stream failure must delete pending store files");
        } catch (Error e) {
            fail_if_reached(@"Receive plain stream failure cleanup test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_receive_decrypt_failure_cleans_encrypted_download_before_store_sync() {
        var loop = new MainLoop();
        test_receive_decrypt_failure_cleans_encrypted_download_before_store.begin((obj, res) => {
            test_receive_decrypt_failure_cleans_encrypted_download_before_store.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_receive_decrypt_failure_cleans_encrypted_download_before_store() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            uint8[] encrypted_payload = "synthetic encrypted payload\n".data;
            var encrypted_stream = new MemoryInputStream.from_data(encrypted_payload);
            var decryptor = new TestFailingFileDecryptor();

            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "payload.pgp";
            file_transfer.mime_type = "application/pgp-encrypted";
            file_transfer.encryption = Dino.Entities.Encryption.PGP;
            file_transfer.size = encrypted_payload.length;

            var file_meta = new Dino.FileMeta();
            file_meta.file_name = file_transfer.file_name;
            file_meta.mime_type = file_transfer.mime_type;
            file_meta.size = encrypted_payload.length;

            bool rejected = false;
            try {
                yield Dino.FileManager.decrypt_received_payload_for_tests(
                        file_transfer, conversation, encrypted_stream, file_meta, decryptor, temp_dir);
                fail_if_reached("receive decrypt failure must fail before store");
            } catch (Dino.FileReceiveError.DECRYPTION_FAILED e) {
                rejected = true;
            } catch (Error e) {
                fail_if_reached(@"Unexpected receive decrypt failure error: $(e.message)");
            }

            fail_if(!rejected, "receive decrypt failure must be rejected");
            fail_if(!decryptor.called, "receive decrypt failure test decryptor must be called");
            fail_if(!decryptor.saw_decrypting_phase, "receive decrypt failure must expose DECRYPTING before rejection");
            fail_if(!encrypted_stream.is_closed(), "receive decrypt failure must close the downloaded payload stream");
            fail_if(file_transfer.path != null, "receive decrypt failure must not publish a storage path");
            fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                "receive decrypt failure must not complete the transfer");
            fail_if(file_transfer.is_plaintext_release_allowed(),
                "receive decrypt failure must not allow plaintext release");
            fail_if(count_directory_entries(temp_dir) != 0,
                "receive decrypt failure must delete the encrypted download temp file before store");
        } catch (Error e) {
            fail_if_reached(@"Receive decrypt failure cleanup test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_receive_stream_decrypt_failure_cleans_pending_before_publish_sync() {
        var loop = new MainLoop();
        test_receive_stream_decrypt_failure_cleans_pending_before_publish.begin((obj, res) => {
            test_receive_stream_decrypt_failure_cleans_pending_before_publish.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_receive_stream_decrypt_failure_cleans_pending_before_publish() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var file_encryption = new Dino.Security.FileEncryption("receive-stream-decrypt-test");
            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            var conversation = new Dino.Entities.Conversation(new Xmpp.Jid("bob@example.test"), account, Dino.Entities.Conversation.Type.CHAT);
            uint8[] encrypted_payload = "synthetic encrypted stream payload\n".data;
            uint8[] plaintext_prefix = "verified bytes before auth failure\n".data;
            var encrypted_stream = new MemoryInputStream.from_data(encrypted_payload);
            var decryptor = new TestStreamingFailingFileDecryptor(plaintext_prefix);

            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "streamed.bin";
            file_transfer.mime_type = "application/octet-stream";
            file_transfer.encryption = Dino.Entities.Encryption.OMEMO;
            file_transfer.size = 98765;
            string original_name = file_transfer.file_name;
            string? original_mime_type = file_transfer.mime_type;
            int64 original_size = file_transfer.size;

            var file_meta = new Dino.FileMeta();
            file_meta.file_name = file_transfer.file_name;
            file_meta.mime_type = file_transfer.mime_type;
            file_meta.size = encrypted_payload.length;

            bool saw_decrypting_phase = false;
            file_transfer.notify["phase"].connect(() => {
                if (file_transfer.phase == Dino.Entities.FileTransfer.Phase.DECRYPTING) {
                    saw_decrypting_phase = true;
                    fail_if(file_transfer.path != null,
                        "streaming decrypt failure must not publish the path while decrypting");
                    fail_if(file_transfer.size != original_size,
                        "streaming decrypt failure must not publish plaintext size while decrypting");
                    fail_if(file_transfer.is_plaintext_release_allowed(),
                        "streaming decrypt failure must not allow plaintext release while decrypting");
                }
                fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.PREVIEWING,
                    "streaming decrypt failure must not expose PREVIEWING");
                fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                    "streaming decrypt failure must not expose COMPLETE");
            });

            bool failed = false;
            try {
                yield Dino.FileManager.decrypt_and_store_received_file_for_tests(
                        file_encryption, file_transfer, conversation, encrypted_stream, file_meta, decryptor, temp_dir);
                fail_if_reached("streaming receive decrypt failure must fail before publish");
            } catch (Error e) {
                failed = true;
            }

            fail_if(!failed, "streaming receive decrypt failure must be rejected");
            fail_if(!decryptor.called, "streaming receive decryptor must be called");
            fail_if(!saw_decrypting_phase, "streaming receive decrypt failure must expose DECRYPTING before rejection");
            fail_if_not_eq_str(file_transfer.file_name, original_name,
                "streaming receive decrypt failure must not change filename");
            fail_if_not_eq_str(file_transfer.mime_type, original_mime_type,
                "streaming receive decrypt failure must not change MIME type");
            fail_if(file_transfer.size != original_size,
                "streaming receive decrypt failure must not publish plaintext size");
            fail_if(file_transfer.path != null,
                "streaming receive decrypt failure must not publish a storage path");
            fail_if(file_transfer.is_plaintext_release_allowed(),
                "streaming receive decrypt failure must not allow plaintext release");
            fail_if(count_directory_entries(temp_dir) != 0,
                "streaming receive decrypt failure must delete encrypted download and pending store files");
        } catch (Error e) {
            fail_if_reached(@"Receive streaming decrypt failure cleanup test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_auto_download_transport_failure_keeps_manual_retry_available_sync() {
        var loop = new MainLoop();
        test_auto_download_transport_failure_keeps_manual_retry_available.begin(null, (obj, res) => {
            test_auto_download_transport_failure_keeps_manual_retry_available.end(res);
            loop.quit();
        });
        loop.run();
    }

    void test_localized_timeout_schedules_retry_sync() {
        foreach (string message in new string[] {
                "Истекло время ожидания I/O сокета", "انتهت مهلة الإدخال والإخراج",
                "入出力の待機時間が切れました", "Bağlantı zaman aşımına uğradı",
                "Zeitüberschreitung beim Lesen", "操作超时" }) {
            var loop = new MainLoop();
            test_auto_download_transport_failure_keeps_manual_retry_available.begin(message, (obj, res) => {
                test_auto_download_transport_failure_keeps_manual_retry_available.end(res);
                loop.quit();
            });
            loop.run();
        }
    }

    async void test_auto_download_transport_failure_keeps_manual_retry_available(string? timeout_message = null) {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Dino.Database? db = null;
        string? stored_path = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "auto-download-transport-failure-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.MessageStorage.start(stream_interactor, (!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);
            Dino.MessageProcessor.start(stream_interactor, (!) db);
            Dino.EntityInfo.start(stream_interactor, (!) db);
            Dino.RosterManager.start(stream_interactor, (!) db);
            Dino.Calls.start(stream_interactor, (!) db);
            Dino.ConversationManager.start(stream_interactor, (!) db);
            Dino.PresenceManager.start(stream_interactor, (!) db);
            Dino.MucManager.start(stream_interactor);

            var file_encryption = new Dino.Security.FileEncryption("auto-download-transport-failure-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            Xmpp.Jid bob_jid = new Xmpp.Jid("bob@example.test");
            var conversation = new Dino.Entities.Conversation(bob_jid, account, Dino.Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);

            stream_interactor.module_manager.initialize(account);
            stream_interactor.account_added(account);

            var conversation_manager = stream_interactor.get_module<Dino.ConversationManager>(Dino.ConversationManager.IDENTITY);
            fail_if(conversation_manager == null, "test setup must start ConversationManager");
            fail_if(((!) conversation_manager).get_conversation(bob_jid, account, Dino.Entities.Conversation.Type.CHAT) == null,
                "test setup must load the persisted direct conversation");

            uint8[] payload = "manual retry payload after transient auto 404\n".data;
            var provider = new TestFailOnceIncomingProvider(992, payload, timeout_message);
            ((!) manager).add_provider(provider);

            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.account = account;
            file_transfer.counterpart = bob_jid;
            file_transfer.ourpart = account.bare_jid;
            file_transfer.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
            file_transfer.time = file_transfer.local_time = new DateTime.now_utc();
            file_transfer.provider = provider.get_id();
            file_transfer.info = "incoming-auto-download-transport-failure";
            file_transfer.file_name = "transient-404.txt";
            file_transfer.mime_type = "text/plain";
            file_transfer.encryption = Dino.Entities.Encryption.NONE;
            file_transfer.size = payload.length;
            file_transfer.persist((!) db);

            yield ((!) manager).auto_download_file(file_transfer);

            fail_if(provider.download_attempts != 1,
                "auto-download must perform exactly one transport attempt");
            fail_if(file_transfer.retry_count != 1 || file_transfer.next_retry_time <= 0,
                "transient failures must schedule a retry independently of the error message language");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.NOT_STARTED,
                "transient auto-download transport failure must keep the transfer manually retryable");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.NONE,
                "transient auto-download transport failure must reset the phase");
            fail_if(file_transfer.phase_error != null,
                "transient auto-download transport failure must not keep a stale phase error");
            fail_if(file_transfer.path != null,
                "transient auto-download transport failure must not publish a storage path");
            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.NOT_STARTED,
                "transient auto-download transport failure must persist NOT_STARTED for manual retry");

            yield ((!) manager).download_file(file_transfer);

            stored_path = file_transfer.path;
            fail_if(provider.download_attempts != 2,
                "manual retry must perform a second transport attempt");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "manual retry after transient auto-download failure must complete");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "manual retry after transient auto-download failure must persist complete state in memory");
            fail_if(file_transfer.phase_error != null,
                "manual retry completion must clear the prior transient error");
            assert_persisted_transfer_state((!) db, file_transfer, Dino.Entities.FileTransfer.State.COMPLETE,
                "manual retry after transient auto-download failure must persist COMPLETE");

            File? stored_file = file_transfer.get_file();
            fail_if(stored_file == null || !((!) stored_file).query_exists(),
                "manual retry after transient auto-download failure must publish the verified local file");
            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal(payload, decrypted),
                "stored manual retry payload must match the provider payload");
        } catch (Error e) {
            fail_if_reached(@"Auto-download transient transport failure retry test failed: $(e.message)");
        } finally {
            if (db != null) {
                ((!) db).close();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            cleanup_export_test_dir(temp_dir);
        }
    }

    private void test_jingle_missing_live_source_is_not_downloadable() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Dino.Database? db = null;

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "jingle-missing-live-source-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            var file_encryption = new Dino.Security.FileEncryption("jingle-missing-live-source-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
            file_transfer.provider = Dino.FileManager.JINGLE_PROVIDER_ID;
            file_transfer.info = "expired-direct-offer";
            file_transfer.state = Dino.Entities.FileTransfer.State.NOT_STARTED;

            fail_if(((!) manager).has_usable_download_source(file_transfer),
                "A received Jingle transfer without a live runtime offer must not be downloadable");

            file_transfer.set_transient_download_source_available(true);
            fail_if(((!) manager).has_usable_download_source(file_transfer),
                "The FileManager must still reject stale Jingle transfers when the provider has no live offer");
        } catch (Error e) {
            fail_if_reached(@"Jingle missing live source test failed: $(e.message)");
        } finally {
            if (db != null) {
                ((!) db).close();
            }
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_download_file_resolves_groupchat_pm_conversation_sync() {
        var loop = new MainLoop();
        test_download_file_resolves_groupchat_pm_conversation.begin((obj, res) => {
            test_download_file_resolves_groupchat_pm_conversation.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_download_file_resolves_groupchat_pm_conversation() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Dino.Database? db = null;
        string? stored_path = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "download-pm-conversation-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.MessageStorage.start(stream_interactor, (!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);
            Dino.MessageProcessor.start(stream_interactor, (!) db);
            Dino.EntityInfo.start(stream_interactor, (!) db);
            Dino.RosterManager.start(stream_interactor, (!) db);
            Dino.Calls.start(stream_interactor, (!) db);
            Dino.ConversationManager.start(stream_interactor, (!) db);
            Dino.PresenceManager.start(stream_interactor, (!) db);
            Dino.MucManager.start(stream_interactor);

            var file_encryption = new Dino.Security.FileEncryption("download-pm-conversation-test");
            Dino.FileManager.start(stream_interactor, (!) db, file_encryption);
            var manager = stream_interactor.get_module<Dino.FileManager>(Dino.FileManager.IDENTITY);
            fail_if(manager == null, "test setup must start FileManager");

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            Xmpp.Jid room_jid = new Xmpp.Jid("room@conference.example.test");
            Xmpp.Jid occupant_jid = room_jid.with_resource("bob");
            Xmpp.Jid own_occupant_jid = room_jid.with_resource("alice");
            var groupchat = new Dino.Entities.Conversation(room_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT);
            groupchat.persist((!) db);
            var private_message = new Dino.Entities.Conversation(occupant_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT_PM);
            private_message.persist((!) db);

            stream_interactor.module_manager.initialize(account);
            stream_interactor.account_added(account);

            var conversation_manager = stream_interactor.get_module<Dino.ConversationManager>(Dino.ConversationManager.IDENTITY);
            fail_if(conversation_manager == null, "test setup must start ConversationManager");
            fail_if(((!) conversation_manager).get_conversation(room_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT) == null,
                "test setup must load the bare room conversation");
            Dino.Entities.Conversation? loaded_pm = ((!) conversation_manager).get_conversation(
                occupant_jid, account, Dino.Entities.Conversation.Type.GROUPCHAT_PM);
            fail_if(loaded_pm == null, "test setup must load the full room/nick PM conversation");

            var provider = new TestPlainIncomingProvider(991);
            var decryptor = new TestCapturingSuccessfulFileDecryptor("verified MUC-PM download plaintext\n");
            ((!) manager).add_provider(provider);
            ((!) manager).add_file_decryptor(decryptor);

            var incoming = new Dino.Entities.FileTransfer();
            incoming.account = account;
            incoming.counterpart = occupant_jid;
            incoming.ourpart = own_occupant_jid;
            incoming.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
            incoming.time = incoming.local_time = new DateTime.now_utc();
            incoming.provider = provider.get_id();
            incoming.info = "incoming-muc-pm-file";
            incoming.file_name = "payload.pgp";
            incoming.mime_type = "application/pgp-encrypted";
            incoming.encryption = Dino.Entities.Encryption.PGP;
            incoming.size = 64;
            incoming.persist((!) db);

            var storage = stream_interactor.get_module<Dino.FileTransferStorage>(Dino.FileTransferStorage.IDENTITY);
            fail_if(storage == null, "test setup must start FileTransferStorage");
            Dino.Entities.FileTransfer? persisted_transfer = ((!) storage).get_file_by_id(incoming.id, (!) loaded_pm);
            fail_if(persisted_transfer == null, "test setup must reload the persisted PM file transfer");
            var file_transfer = (!) persisted_transfer;

            yield ((!) manager).download_file(file_transfer);

            stored_path = file_transfer.path;
            fail_if(!provider.download_called, "manual download must call the selected persisted provider");
            fail_if(!decryptor.decrypt_called, "manual download must call the registered decryptor");
            fail_if(decryptor.prepare_conversation_type != (int) Dino.Entities.Conversation.Type.GROUPCHAT_PM,
                "manual download must prepare the decryptor with the full MUC-PM conversation, not the bare room");
            fail_if(decryptor.decrypt_conversation_type != (int) Dino.Entities.Conversation.Type.GROUPCHAT_PM,
                "manual download must decrypt with the full MUC-PM conversation, not the bare room");
            fail_if_not_eq_str(decryptor.prepare_counterpart ?? "", occupant_jid.to_string(),
                "manual download must preserve the full room/nick counterpart during decryptor preparation");
            fail_if_not_eq_str(decryptor.decrypt_counterpart ?? "", occupant_jid.to_string(),
                "manual download must preserve the full room/nick counterpart during decrypt");
            fail_if(file_transfer.phase != Dino.Entities.FileTransfer.Phase.COMPLETE,
                "successful persisted MUC-PM manual download must complete");
            fail_if(file_transfer.state != Dino.Entities.FileTransfer.State.COMPLETE,
                "successful persisted MUC-PM manual download must persist complete state");
            fail_if(file_transfer.phase_error != null,
                "successful persisted MUC-PM manual download must not keep a phase error");

            File? stored_file = file_transfer.get_file();
            fail_if(stored_file == null || !((!) stored_file).query_exists(),
                "successful persisted MUC-PM manual download must publish the verified local file");
            var decrypted_output = new MemoryOutputStream.resizable();
            yield file_encryption.decrypt_file_to_stream((!) stored_file, decrypted_output, null);
            uint8[] decrypted = decrypted_output.steal_data();
            decrypted.length = (int) decrypted_output.get_data_size();
            fail_if(!bytes_equal("verified MUC-PM download plaintext\n".data, decrypted),
                "stored MUC-PM manual download must decrypt to the decryptor plaintext");
        } catch (Error e) {
            fail_if_reached(@"MUC-PM manual download conversation resolution test failed: $(e.message)");
        } finally {
            if (db != null) {
                ((!) db).close();
            }
            if (stored_path != null) {
                FileUtils.remove(Path.build_filename(Dino.FileManager.get_storage_dir(), (!) stored_path));
            }
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_save_outgoing_file_keeps_existing_final_on_collision_sync() {
        var loop = new MainLoop();
        test_save_outgoing_file_keeps_existing_final_on_collision.begin((obj, res) => {
            test_save_outgoing_file_keeps_existing_final_on_collision.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_save_outgoing_file_keeps_existing_final_on_collision() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string existing_path = Path.build_filename(temp_dir, "existing.txt");
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            FileUtils.set_contents(existing_path, "keep existing\n");
            var file_encryption = new Dino.Security.FileEncryption("save-collision-test");
            uint8[] plaintext = "new outgoing plaintext\n".data;
            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "existing.txt";
            file_transfer.size = plaintext.length;

            bool failed = false;
            try {
                yield Dino.FileManager.save_outgoing_file_for_tests(
                        file_encryption, file_transfer, new MemoryInputStream.from_data(plaintext), temp_dir, "existing.txt");
            } catch (Dino.FileSendError.SAVE_FAILED e) {
                failed = true;
            }

            string existing_contents;
            FileUtils.get_contents(existing_path, out existing_contents);
            fail_if(!failed, "outgoing save must fail when the final filename already exists");
            fail_if_not_eq_str(existing_contents, "keep existing\n",
                "outgoing save cleanup must not delete or replace an existing final file");
            fail_if(file_transfer.path != null, "failed outgoing save must not publish a storage path");
            fail_if(count_send_pending_files(temp_dir) != 0, "final collision must clean the pending outgoing file");
        } catch (Error e) {
            fail_if_reached(@"Outgoing save collision test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_unpublished_outgoing_cleanup_removes_committed_file() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string committed_name = "committed.enc";
        string committed_path = Path.build_filename(temp_dir, committed_name);
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            FileUtils.set_contents(committed_path, "encrypted local copy\n");

            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "report.txt";
            file_transfer.path = committed_name;

            Dino.FileManager.delete_unpublished_outgoing_file_for_tests(file_transfer, temp_dir, committed_name);

            fail_if(FileUtils.test(committed_path, FileTest.EXISTS),
                "unpublished outgoing cleanup must remove the committed local file");
            fail_if(file_transfer.path != null,
                "unpublished outgoing cleanup must clear the transfer storage path");
        } catch (Error e) {
            fail_if_reached(@"Unpublished outgoing cleanup test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_export_plaintext_source_streams_to_target_sync() {
        var loop = new MainLoop();
        test_export_plaintext_source_streams_to_target.begin((obj, res) => {
            test_export_plaintext_source_streams_to_target.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_export_plaintext_source_streams_to_target() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string source_path = Path.build_filename(temp_dir, "stored.enc");
        string target_path = Path.build_filename(temp_dir, "report.txt");
        string lease_root = Path.build_filename(temp_dir, "dinox", "temp_plaintext");

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var file_encryption = new Dino.Security.FileEncryption("export-test");
            uint8[] plaintext = "exported plaintext\n".data;
            yield write_encrypted_export_source(file_encryption, File.new_for_path(source_path), plaintext);
            FileUtils.set_contents(target_path, "old target\n");

            yield Dino.FileManager.export_plaintext_source_to_target_for_tests(file_encryption,
                    File.new_for_path(source_path), File.new_for_path(target_path), lease_root);

            string target_contents;
            FileUtils.get_contents(target_path, out target_contents);
            fail_if_not_eq_str(target_contents, "exported plaintext\n", "export must replace the target with decrypted plaintext");
            fail_if(count_export_pending_files(temp_dir) != 0, "successful export must not leave a pending file");
        } catch (Error e) {
            fail_if_reached(@"Plaintext export success test failed: $(e.message)");
        } finally {
            Dino.FileManager.cleanup_plaintext_lease_root_for_tests(lease_root);
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_export_plaintext_source_keeps_target_on_decrypt_error_sync() {
        var loop = new MainLoop();
        test_export_plaintext_source_keeps_target_on_decrypt_error.begin((obj, res) => {
            test_export_plaintext_source_keeps_target_on_decrypt_error.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_export_plaintext_source_keeps_target_on_decrypt_error() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string source_path = Path.build_filename(temp_dir, "stored.enc");
        string target_path = Path.build_filename(temp_dir, "report.txt");
        string lease_root = Path.build_filename(temp_dir, "dinox", "temp_plaintext");

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            var correct_encryption = new Dino.Security.FileEncryption("correct-export-test");
            var wrong_encryption = new Dino.Security.FileEncryption("wrong-export-test");
            uint8[] plaintext = "authenticated plaintext\n".data;
            yield write_encrypted_export_source(correct_encryption, File.new_for_path(source_path), plaintext);
            FileUtils.set_contents(target_path, "old target\n");

            bool export_failed = false;
            try {
                yield Dino.FileManager.export_plaintext_source_to_target_for_tests(wrong_encryption,
                        File.new_for_path(source_path), File.new_for_path(target_path), lease_root);
            } catch (Error e) {
                export_failed = true;
            }

            fail_if(!export_failed, "export must fail when at-rest decryption fails");
            string target_contents;
            FileUtils.get_contents(target_path, out target_contents);
            fail_if_not_eq_str(target_contents, "old target\n", "failed export must keep the original target");
            fail_if(count_export_pending_files(temp_dir) != 0, "failed export must clean the pending file");
        } catch (Error e) {
            fail_if_reached(@"Plaintext export failure test failed: $(e.message)");
        } finally {
            Dino.FileManager.cleanup_plaintext_lease_root_for_tests(lease_root);
            cleanup_export_test_dir(temp_dir);
        }
    }

    void test_export_plaintext_file_rejects_incomplete_transfer_sync() {
        var loop = new MainLoop();
        test_export_plaintext_file_rejects_incomplete_transfer.begin((obj, res) => {
            test_export_plaintext_file_rejects_incomplete_transfer.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_export_plaintext_file_rejects_incomplete_transfer() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        string target_path = Path.build_filename(temp_dir, "report.txt");

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            FileUtils.set_contents(target_path, "existing target\n");

            var manager = Dino.FileManager.create_for_tests();
            Dino.Entities.FileTransfer.State[] states = {
                Dino.Entities.FileTransfer.State.NOT_STARTED,
                Dino.Entities.FileTransfer.State.IN_PROGRESS,
                Dino.Entities.FileTransfer.State.FAILED
            };

            foreach (Dino.Entities.FileTransfer.State state in states) {
                var file_transfer = create_incomplete_received_transfer_for_plaintext_release_test(state);

                bool denied = false;
                try {
                    yield manager.export_plaintext_file(file_transfer, File.new_for_path(target_path));
                } catch (IOError.PERMISSION_DENIED e) {
                    denied = true;
                } catch (Error e) {
                    fail_if_reached(@"Incomplete transfer export guard raised unexpected error: $(e.message)");
                }

                fail_if(!denied, "incomplete transfers must not export plaintext");
                string target_contents;
                FileUtils.get_contents(target_path, out target_contents);
                fail_if_not_eq_str(target_contents, "existing target\n", "blocked export must leave the selected target untouched");
                fail_if(count_export_pending_files(temp_dir) != 0, "blocked export must not create a pending target file");
            }
        } catch (Error e) {
            fail_if_reached(@"Incomplete transfer export guard test failed: $(e.message)");
        } finally {
            cleanup_export_test_dir(temp_dir);
        }
    }

    private Dino.Entities.FileTransfer create_incomplete_received_transfer_for_plaintext_release_test(Dino.Entities.FileTransfer.State state) {
        var file_transfer = new Dino.Entities.FileTransfer();
        file_transfer.file_name = "pending.txt";
        file_transfer.path = "not-yet-released.enc";
        file_transfer.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
        switch (state) {
            case Dino.Entities.FileTransfer.State.NOT_STARTED:
                file_transfer.set_transfer_phase(Dino.Entities.FileTransfer.Phase.NONE);
                break;
            case Dino.Entities.FileTransfer.State.IN_PROGRESS:
                file_transfer.set_transfer_phase(Dino.Entities.FileTransfer.Phase.VERIFYING);
                break;
            case Dino.Entities.FileTransfer.State.FAILED:
                file_transfer.set_transfer_phase(Dino.Entities.FileTransfer.Phase.FAILED, "synthetic failure");
                break;
            case Dino.Entities.FileTransfer.State.COMPLETE:
                file_transfer.set_transfer_phase(Dino.Entities.FileTransfer.Phase.COMPLETE);
                break;
        }
        return file_transfer;
    }

    private Dino.Entities.FileTransfer create_stored_received_transfer_for_plaintext_release_test(string storage_name, int64 size, Dino.Entities.FileTransfer.Phase phase) {
        var file_transfer = new Dino.Entities.FileTransfer();
        file_transfer.file_name = "gate4.txt";
        file_transfer.path = storage_name;
        file_transfer.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
        file_transfer.size = size;
        file_transfer.set_transfer_phase(phase, phase == Dino.Entities.FileTransfer.Phase.FAILED ? "synthetic failure" : null);
        return file_transfer;
    }

    private async void write_encrypted_export_source(Dino.Security.FileEncryption file_encryption, File source_file, uint8[] plaintext) throws Error {
        var input = new MemoryInputStream.from_data(plaintext);
        OutputStream? output = null;
        try {
            output = source_file.create(FileCreateFlags.PRIVATE);
            yield file_encryption.encrypt_stream(input, (!) output, null);
            yield ((!) output).close_async(Priority.LOW, null);
            output = null;
        } finally {
            if (output != null) {
                try { ((!) output).close(null); } catch (Error e) {}
            }
            try { input.close(null); } catch (Error e) {}
        }
    }

    private int count_export_pending_files(string directory_path) throws Error {
        File directory = File.new_for_path(directory_path);
        FileEnumerator enumerator = directory.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        int count = 0;
        FileInfo? child_info;
        while ((child_info = enumerator.next_file()) != null) {
            string name = ((!) child_info).get_name();
            if (name.has_prefix(".dinox-export-") && name.has_suffix(".part")) {
                count++;
            }
        }
        enumerator.close();
        return count;
    }

    private int count_send_pending_files(string directory_path) throws Error {
        File directory = File.new_for_path(directory_path);
        FileEnumerator enumerator = directory.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        int count = 0;
        FileInfo? child_info;
        while ((child_info = enumerator.next_file()) != null) {
            string name = ((!) child_info).get_name();
            if (name.has_prefix(".send-") && name.has_suffix(".part")) {
                count++;
            }
        }
        enumerator.close();
        return count;
    }

    private int count_receive_pending_files_for_basename(string directory_path, string basename) throws Error {
        File directory = File.new_for_path(directory_path);
        if (!directory.query_exists()) return 0;

        FileEnumerator enumerator = directory.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        int count = 0;
        FileInfo? child_info;
        while ((child_info = enumerator.next_file()) != null) {
            string name = ((!) child_info).get_name();
            if (name.has_prefix(".download-") && name.has_suffix("_" + basename + ".part")) {
                count++;
            }
        }
        enumerator.close();
        return count;
    }

    private void delete_receive_pending_files_for_basename(string directory_path, string basename) {
        File directory = File.new_for_path(directory_path);
        if (!directory.query_exists()) return;

        FileEnumerator? enumerator = null;
        try {
            enumerator = directory.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child_info;
            while ((child_info = ((!) enumerator).next_file()) != null) {
                string name = ((!) child_info).get_name();
                if (name.has_prefix(".download-") && name.has_suffix("_" + basename + ".part")) {
                    try {
                        directory.get_child(name).delete(null);
                    } catch (Error e) {
                    }
                }
            }
        } catch (Error e) {
        } finally {
            if (enumerator != null) {
                try { ((!) enumerator).close(null); } catch (Error e) {}
            }
        }
    }

    private int count_directory_entries(string directory_path) throws Error {
        File directory = File.new_for_path(directory_path);
        FileEnumerator enumerator = directory.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        int count = 0;
        FileInfo? child_info;
        while ((child_info = enumerator.next_file()) != null) {
            count++;
        }
        enumerator.close();
        return count;
    }

    private bool bytes_equal(uint8[] left, uint8[] right) {
        if (left.length != right.length) return false;
        for (int i = 0; i < left.length; i++) {
            if (left[i] != right[i]) return false;
        }
        return true;
    }

    private void assert_pattern_bytes(uint8[] data, int64 expected_size, string reason) {
        fail_if(data.length != expected_size, reason);
        for (int i = 0; i < data.length; i++) {
            fail_if(data[i] != DeterministicLargeInputStream.pattern_byte_at(i), reason);
        }
    }

    private void cleanup_export_test_dir(string temp_dir) {
        File directory = File.new_for_path(temp_dir);
        try {
            FileEnumerator enumerator = directory.enumerate_children(FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child_info;
            while ((child_info = enumerator.next_file()) != null) {
                try { directory.get_child(((!) child_info).get_name()).delete(null); } catch (Error e) {}
            }
            enumerator.close();
        } catch (Error e) {}
        DirUtils.remove(temp_dir);
    }

    void test_verify_and_commit_rejects_hash_mismatch_sync() {
        var loop = new MainLoop();
        test_verify_and_commit_rejects_hash_mismatch.begin((obj, res) => {
            test_verify_and_commit_rejects_hash_mismatch.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_verify_and_commit_rejects_hash_mismatch() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        File pending_file = File.new_for_path(Path.build_filename(temp_dir, ".pending-report.part"));
        File final_file = File.new_for_path(Path.build_filename(temp_dir, "stored-report"));
        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            var file_encryption = new Dino.Security.FileEncryption("test");
            uint8[] plaintext = "confidential report contents\n".data;
            var plaintext_stream = new MemoryInputStream.from_data(plaintext);
            OutputStream pending_output = pending_file.create(FileCreateFlags.PRIVATE);
            yield file_encryption.encrypt_stream(plaintext_stream, pending_output, null);
            yield pending_output.close_async();

            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "report.txt.pgp";
            file_transfer.mime_type = "application/pgp-encrypted";
            file_transfer.size = 98765;
            file_transfer.path = null;
            file_transfer.set_transfer_phase(Dino.Entities.FileTransfer.Phase.STORING);

            string original_name = file_transfer.file_name;
            string? original_mime_type = file_transfer.mime_type;
            int64 original_size = file_transfer.size;
            Dino.Entities.FileTransfer.State original_state = file_transfer.state;

            uint8[] wrong_sha256 = new uint8[32];
            file_transfer.hashes.add(new Xmpp.Xep.CryptographicHashes.Hash.with_checksum(ChecksumType.SHA256, Base64.encode(wrong_sha256)));
            bool saw_verifying_phase = false;
            file_transfer.notify["phase"].connect(() => {
                if (file_transfer.phase == Dino.Entities.FileTransfer.Phase.VERIFYING) {
                    saw_verifying_phase = true;
                    fail_if(file_transfer.path != null, "hash verification must not publish the path before commit");
                    fail_if(file_transfer.size != original_size, "hash verification must not publish the plaintext size before commit");
                    fail_if(file_transfer.is_plaintext_release_allowed(),
                        "plaintext release must remain blocked during hash verification");
                    fail_if(final_file.query_exists(),
                        "final committed file must not exist during hash verification");
                }
            });

            var verified_meta = new Dino.VerifiedPlaintextMeta() {
                file_name = "report.txt",
                mime_type = "text/plain"
            };

            try {
                GLib.Test.expect_message("libdino", GLib.LogLevelFlags.LEVEL_WARNING, "*Hash mismatch for 'report.txt.pgp'*");
                yield Dino.FileManager.verify_and_commit_received_file(file_transfer, file_encryption, pending_file, final_file, plaintext.length, plaintext, verified_meta);
                fail_if_reached("Hash mismatch must fail before committing the received file");
            } catch (Dino.FileReceiveError.DECRYPTION_FAILED e) {
                GLib.Test.assert_expected_messages();
                assert_true(true);
            } catch (Error e) {
                fail_if_reached(@"Unexpected commit error: $(e.message)");
            }

            fail_if(!saw_verifying_phase, "hash-only verification must expose VERIFYING phase before rejection");
            fail_if_not_eq_str(file_transfer.file_name, original_name, "verified plaintext filename must not be published");
            fail_if_not_eq_str(file_transfer.mime_type, original_mime_type, "verified plaintext MIME type must not be published");
            fail_if(file_transfer.path != null, "path must not be published");
            fail_if(file_transfer.size != original_size, "plaintext size must not be published");
            fail_if(file_transfer.state != original_state, "transfer state must not be completed");
            fail_if(file_transfer.is_plaintext_release_allowed(), "plaintext release must remain blocked");
            fail_if(final_file.query_exists(), "final committed file must not exist");
        } catch (Error e) {
            fail_if_reached(@"Test setup failed: $(e.message)");
        } finally {
            try { pending_file.delete(null); } catch (Error e) {}
            try { final_file.delete(null); } catch (Error e) {}
            DirUtils.remove(temp_dir);
        }
    }

    void test_verify_and_commit_sets_verifying_before_publish_sync() {
        var loop = new MainLoop();
        test_verify_and_commit_sets_verifying_before_publish.begin((obj, res) => {
            test_verify_and_commit_sets_verifying_before_publish.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_verify_and_commit_sets_verifying_before_publish() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        File pending_file = File.new_for_path(Path.build_filename(temp_dir, ".pending-report.part"));
        File final_file = File.new_for_path(Path.build_filename(temp_dir, "stored-report"));

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            var file_encryption = new Dino.Security.FileEncryption("test");
            uint8[] plaintext = "authenticated plaintext\n".data;
            yield write_encrypted_export_source(file_encryption, pending_file, plaintext);

            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "report.txt.pgp";
            file_transfer.mime_type = "application/pgp-encrypted";
            file_transfer.encryption = Dino.Entities.Encryption.PGP;
            file_transfer.size = 98765;
            file_transfer.path = null;
            file_transfer.set_transfer_phase(Dino.Entities.FileTransfer.Phase.STORING);

            var verified_meta = new Dino.VerifiedPlaintextMeta() {
                file_name = "report.txt",
                mime_type = "text/plain"
            };

            var phases = new Gee.ArrayList<int>();
            file_transfer.notify["phase"].connect(() => {
                phases.add((int) file_transfer.phase);
                if (file_transfer.phase == Dino.Entities.FileTransfer.Phase.VERIFYING) {
                    fail_if_not_eq_str(file_transfer.file_name, "report.txt.pgp",
                        "verified plaintext filename must not be published before verification");
                    fail_if_not_eq_str((!) file_transfer.mime_type, "application/pgp-encrypted",
                        "verified plaintext MIME must not be published before verification");
                    fail_if(file_transfer.path != null, "path must not be published before verification");
                    fail_if(file_transfer.size != 98765, "plaintext size must not be published before verification");
                    fail_if(file_transfer.is_plaintext_release_allowed(),
                        "plaintext release must remain blocked during verification");
                    fail_if(final_file.query_exists(),
                        "final committed file must not exist during verification");
                }
                if (file_transfer.phase == Dino.Entities.FileTransfer.Phase.PREVIEWING) {
                    fail_if(!final_file.query_exists(),
                        "final committed file must exist before PREVIEWING");
                    fail_if(file_transfer.path == null,
                        "stored path may be published only after commit and before preview");
                    fail_if(file_transfer.size != plaintext.length,
                        "plaintext size may be published only after commit and before preview");
                    fail_if(file_transfer.is_plaintext_release_allowed(),
                        "plaintext release must remain blocked during PREVIEWING");
                }
            });

            File committed_file = yield Dino.FileManager.verify_and_commit_received_file(
                    file_transfer, file_encryption, pending_file, final_file, plaintext.length, plaintext, verified_meta);

            fail_if(!committed_file.equal(final_file), "commit must return the final file");
            fail_if(pending_file.query_exists(), "pending file must be moved away after successful commit");
            fail_if(!final_file.query_exists(), "final committed file must exist after successful commit");
            fail_if_not_eq_str(file_transfer.file_name, "report.txt",
                "verified plaintext filename must be published after commit");
            fail_if_not_eq_str((!) file_transfer.mime_type, "text/plain",
                "verified plaintext MIME must be published after commit");
            fail_if_not_eq_str((!) file_transfer.path, final_file.get_basename(),
                "stored path must be published after commit");
            fail_if(file_transfer.size != plaintext.length,
                "plaintext size must be published after commit");
            fail_if(!file_transfer.is_plaintext_release_allowed(),
                "plaintext release must be allowed only after complete commit");

            fail_if(phases.size != 3, "commit must expose VERIFYING, PREVIEWING and COMPLETE phases");
            fail_if(phases[0] != (int) Dino.Entities.FileTransfer.Phase.VERIFYING,
                "first commit phase must be VERIFYING");
            fail_if(phases[1] != (int) Dino.Entities.FileTransfer.Phase.PREVIEWING,
                "second commit phase must be PREVIEWING");
            fail_if(phases[2] != (int) Dino.Entities.FileTransfer.Phase.COMPLETE,
                "final commit phase must be COMPLETE");
        } catch (Error e) {
            fail_if_reached(@"Verify-and-commit phase test failed: $(e.message)");
        } finally {
            try { pending_file.delete(null); } catch (Error e) {}
            try { final_file.delete(null); } catch (Error e) {}
            DirUtils.remove(temp_dir);
        }
    }

    void test_verify_and_commit_collision_keeps_metadata_unpublished_sync() {
        var loop = new MainLoop();
        test_verify_and_commit_collision_keeps_metadata_unpublished.begin((obj, res) => {
            test_verify_and_commit_collision_keeps_metadata_unpublished.end(res);
            loop.quit();
        });
        loop.run();
    }

    async void test_verify_and_commit_collision_keeps_metadata_unpublished() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-" + Uuid.string_random());
        File pending_file = File.new_for_path(Path.build_filename(temp_dir, ".pending-report.part"));
        File final_file = File.new_for_path(Path.build_filename(temp_dir, "stored-report"));

        try {
            DirUtils.create_with_parents(temp_dir, 0700);

            var file_encryption = new Dino.Security.FileEncryption("commit-collision-test");
            uint8[] plaintext = "authenticated plaintext before collision\n".data;
            yield write_encrypted_export_source(file_encryption, pending_file, plaintext);
            FileUtils.set_contents(final_file.get_path(), "existing final\n");

            var file_transfer = new Dino.Entities.FileTransfer();
            file_transfer.file_name = "report.txt.pgp";
            file_transfer.mime_type = "application/pgp-encrypted";
            file_transfer.encryption = Dino.Entities.Encryption.PGP;
            file_transfer.size = 98765;
            file_transfer.path = null;
            file_transfer.set_transfer_phase(Dino.Entities.FileTransfer.Phase.STORING);

            string original_name = file_transfer.file_name;
            string? original_mime_type = file_transfer.mime_type;
            int64 original_size = file_transfer.size;
            Dino.Entities.FileTransfer.State original_state = file_transfer.state;

            var verified_meta = new Dino.VerifiedPlaintextMeta() {
                file_name = "report.txt",
                mime_type = "text/plain"
            };

            var phases = new Gee.ArrayList<int>();
            file_transfer.notify["phase"].connect(() => {
                phases.add((int) file_transfer.phase);
                fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.PREVIEWING,
                    "commit collision must not expose PREVIEWING");
                fail_if(file_transfer.phase == Dino.Entities.FileTransfer.Phase.COMPLETE,
                    "commit collision must not expose COMPLETE");
            });

            bool failed = false;
            try {
                yield Dino.FileManager.verify_and_commit_received_file(
                        file_transfer, file_encryption, pending_file, final_file, plaintext.length, plaintext, verified_meta);
                fail_if_reached("commit collision must fail before publishing received metadata");
            } catch (Error e) {
                failed = true;
            }

            string final_contents;
            FileUtils.get_contents(final_file.get_path(), out final_contents);
            fail_if(!failed, "commit collision must fail");
            fail_if_not_eq_str(final_contents, "existing final\n",
                "commit collision must not replace an existing final file");
            fail_if(!pending_file.query_exists(),
                "direct verify_and_commit collision must leave pending cleanup to the caller");
            fail_if_not_eq_str(file_transfer.file_name, original_name,
                "commit collision must not publish verified plaintext filename");
            fail_if_not_eq_str(file_transfer.mime_type, original_mime_type,
                "commit collision must not publish verified plaintext MIME");
            fail_if(file_transfer.path != null, "commit collision must not publish a storage path");
            fail_if(file_transfer.size != original_size,
                "commit collision must not publish plaintext size");
            fail_if(file_transfer.state != original_state,
                "commit collision must not complete persistent transfer state");
            fail_if(file_transfer.is_plaintext_release_allowed(),
                "commit collision must not allow plaintext release");
            fail_if(phases.size != 1 || phases[0] != (int) Dino.Entities.FileTransfer.Phase.VERIFYING,
                "commit collision must stop after VERIFYING and before PREVIEWING/COMPLETE");
        } catch (Error e) {
            fail_if_reached(@"Verify-and-commit collision test failed: $(e.message)");
        } finally {
            try { pending_file.delete(null); } catch (Error e) {}
            try { final_file.delete(null); } catch (Error e) {}
            DirUtils.remove(temp_dir);
        }
    }
}

private class FileManagerJingleTestXmppStream : Xmpp.XmppStream {
    public ArrayList<StanzaNode> written_nodes = new ArrayList<StanzaNode>();

    public FileManagerJingleTestXmppStream(Xmpp.Jid remote_name) {
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
    }

    public void emit_iq_result(StanzaNode node) {
        received_iq_stanza(this, node);
    }

    public override async void setup() throws IOError {
    }
}

private class FileManagerTestJingleFileEncryptionHelper : Object, Dino.JingleFileEncryptionHelper {
    public bool can_transfer(Dino.Entities.Conversation conversation) {
        return true;
    }

    public async bool can_encrypt(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Xmpp.Jid? full_jid) {
        return false;
    }

    public string? get_precondition_name(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return null;
    }

    public Object? get_precondition_options(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return null;
    }

    public Dino.Entities.Encryption get_encryption(Xmpp.Xep.JingleFileTransfer.FileTransfer jingle_transfer) {
        Xmpp.Xep.Jet.SecurityParameters? security = jingle_transfer.security as Xmpp.Xep.Jet.SecurityParameters;
        if (security != null &&
                ((!) security).encoding.get_type_uri() == "urn:xmpp:test:jet-envelope" &&
                ((!) security).cipher.get_cipher_uri() == "urn:xmpp:test:xor-stream") {
            return Dino.Entities.Encryption.OMEMO;
        }
        return Dino.Entities.Encryption.NONE;
    }
}

private class FileManagerTestJetEnvelope : Xmpp.Xep.Jet.EnvelopEncoding, Object {
    public string get_type_uri() {
        return "urn:xmpp:test:jet-envelope";
    }

    public Xmpp.Xep.Jet.TransportSecret decode_envolop(XmppStream stream, Xmpp.Jid local_full_jid, Xmpp.Jid peer_full_jid,
            StanzaNode security) throws Xmpp.Xep.Jingle.IqError {
        if (security.get_attribute("test-key") != "5a") {
            throw new Xmpp.Xep.Jingle.IqError.BAD_REQUEST("missing test JET key");
        }
        string? tag = security.get_attribute("test-tag");
        if (tag == null) {
            throw new Xmpp.Xep.Jingle.IqError.BAD_REQUEST("missing test JET tag");
        }
        int expected_tag = int.parse((!) tag);
        if (expected_tag < 0 || expected_tag > 255) {
            throw new Xmpp.Xep.Jingle.IqError.BAD_REQUEST("invalid test JET tag");
        }
        uint8[] secret = new uint8[2];
        secret[0] = FileManagerTestJetCipher.KEY;
        secret[1] = (uint8) expected_tag;
        return new Xmpp.Xep.Jet.TransportSecret(secret, new uint8[0]);
    }

    public void encode_envelop(XmppStream stream, Xmpp.Jid local_full_jid, Xmpp.Jid peer_full_jid,
            Xmpp.Xep.Jet.SecurityParameters security_params, StanzaNode security) throws Xmpp.Xep.Jingle.Error {
        security.put_attribute("test-key", "5a");
        security.put_attribute("test-tag", "0");
    }
}

private class FileManagerTestJetCipher : Xmpp.Xep.Jet.Cipher, Object {
    public const uint8 KEY = 0x5a;
    public static bool input_authentication_attempted = false;
    public static bool input_authenticated = false;

    public static void reset_authentication() {
        input_authentication_attempted = false;
        input_authenticated = false;
    }

    public string get_cipher_uri() {
        return "urn:xmpp:test:xor-stream";
    }

    public Xmpp.Xep.Jet.TransportSecret generate_random_secret() {
        uint8[] secret = new uint8[2];
        secret[0] = KEY;
        secret[1] = 0;
        return new Xmpp.Xep.Jet.TransportSecret(secret, new uint8[0]);
    }

    public InputStream wrap_input_stream(InputStream input, Xmpp.Xep.Jet.TransportSecret secret) {
        reset_authentication();
        return new FileManagerXorInputStream(input, key_from_secret(secret), tag_from_secret(secret));
    }

    public OutputStream wrap_output_stream(OutputStream output, Xmpp.Xep.Jet.TransportSecret secret) {
        return new FileManagerXorOutputStream(output, key_from_secret(secret));
    }

    private static uint8 key_from_secret(Xmpp.Xep.Jet.TransportSecret secret) {
        assert(secret.transport_key.length >= 1);
        return secret.transport_key[0];
    }

    private static uint8 tag_from_secret(Xmpp.Xep.Jet.TransportSecret secret) {
        assert(secret.transport_key.length >= 2);
        return secret.transport_key[1];
    }
}

private class FileManagerXorInputStream : InputStream, Xmpp.Xep.Jingle.AuthenticatedInputStream {
    private InputStream inner;
    private uint8 key;
    private uint8 expected_tag;
    private int64 expected_plaintext_size = -1;
    private int64 plaintext_bytes = 0;
    private uint checksum = 0;

    public FileManagerXorInputStream(InputStream inner, uint8 key, uint8 expected_tag) {
        this.inner = inner;
        this.key = key;
        this.expected_tag = expected_tag;
    }

    public override ssize_t read(uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        ssize_t read = inner.read(buffer, cancellable);
        xor_and_track(buffer, read);
        return read;
    }

    public override async ssize_t read_async(uint8[]? buffer, int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        ssize_t read = yield inner.read_async(buffer, io_priority, cancellable);
        if (buffer != null) {
            xor_and_track((!) buffer, read);
        }
        return read;
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        return inner.close(cancellable);
    }

    public override async bool close_async(int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        return yield inner.close_async(io_priority, cancellable);
    }

    public void set_expected_plaintext_size(int64 plaintext_size) {
        expected_plaintext_size = plaintext_size;
    }

    public void authenticate(Cancellable? cancellable = null) throws IOError {
        authenticate_now();
    }

    public async void authenticate_async(int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        authenticate_now();
    }

    private void xor_and_track(uint8[] buffer, ssize_t read) {
        if (read <= 0) return;
        for (int i = 0; i < read; i++) {
            buffer[i] = (uint8) (buffer[i] ^ key);
            checksum = (checksum + buffer[i]) & 0xff;
        }
        plaintext_bytes += read;
    }

    private void authenticate_now() throws IOError {
        FileManagerTestJetCipher.input_authentication_attempted = true;
        if (expected_plaintext_size < 0) {
            throw new IOError.FAILED("test JET stream did not receive expected plaintext size");
        }
        if (plaintext_bytes != expected_plaintext_size) {
            throw new IOError.FAILED("test JET stream plaintext size mismatch");
        }
        if ((uint8) checksum != expected_tag) {
            throw new IOError.FAILED("test JET authentication failed");
        }
        FileManagerTestJetCipher.input_authenticated = true;
    }
}

private class FileManagerXorOutputStream : OutputStream {
    private OutputStream inner;
    private uint8 key;

    public FileManagerXorOutputStream(OutputStream inner, uint8 key) {
        this.inner = inner;
        this.key = key;
    }

    public override ssize_t write(uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        uint8[] encrypted = xor_copy(buffer);
        return inner.write(encrypted, cancellable);
    }

    public override async ssize_t write_async(uint8[]? buffer, int io_priority = Priority.DEFAULT,
            Cancellable? cancellable = null) throws IOError {
        if (buffer == null) {
            return yield inner.write_async(buffer, io_priority, cancellable);
        }
        uint8[] encrypted = xor_copy((!) buffer);
        return yield inner.write_async(encrypted, io_priority, cancellable);
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        return inner.close(cancellable);
    }

    public override async bool close_async(int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        return yield inner.close_async(io_priority, cancellable);
    }

    private uint8[] xor_copy(uint8[] buffer) {
        uint8[] encrypted = new uint8[buffer.length];
        for (int i = 0; i < buffer.length; i++) {
            encrypted[i] = (uint8) (buffer[i] ^ key);
        }
        return encrypted;
    }
}

private class FileManagerHiddenServiceS5BTarget : Object {
    private SocketListener listener = new SocketListener();
    private string? expected_dstaddr = null;
    private Error? warmup_failure = null;
    private Error? failure = null;
    private bool warmup_completed = false;
    private bool completed = false;
    private bool closed = false;
    private MainLoop? warmup_loop = null;
    private MainLoop? loop = null;

    public int port { get; private set; }
    public SocketConnection? connection { get; private set; default = null; }

    public FileManagerHiddenServiceS5BTarget() throws Error {
        InetSocketAddress addr = new InetSocketAddress.from_string("127.0.0.1", 0);
        SocketAddress effective_any;
        listener.add_address(addr, SocketType.STREAM, SocketProtocol.DEFAULT, null, out effective_any);
        InetSocketAddress effective = (InetSocketAddress) effective_any;
        port = (int) effective.port;
    }

    public void expect_warmup() {
        accept_warmup_once.begin((_, res) => {
            try {
                accept_warmup_once.end(res);
            } catch (Error e) {
                if (!closed) {
                    warmup_failure = e;
                }
            }
            warmup_completed = true;
            if (warmup_loop != null) {
                ((!) warmup_loop).quit();
            }
        });
    }

    public void wait_until_warmup_completed(uint timeout_ms) throws Error {
        wait_for_completion(ref warmup_completed, ref warmup_loop, timeout_ms, "Timed out waiting for FileManager Tor onion warmup connection");
        if (warmup_failure != null) {
            throw (!) warmup_failure;
        }
    }

    public void expect(string dstaddr) {
        expected_dstaddr = dstaddr;
        accept_s5b_once.begin((_, res) => {
            try {
                accept_s5b_once.end(res);
            } catch (Error e) {
                if (!closed) {
                    failure = e;
                }
            }
            completed = true;
            if (loop != null) {
                ((!) loop).quit();
            }
        });
    }

    public void wait_until_connected(uint timeout_ms) throws Error {
        wait_for_completion(ref completed, ref loop, timeout_ms, "Timed out waiting for FileManager Tor onion S5B target connection");
        if (failure != null) {
            throw (!) failure;
        }
        if (connection == null) {
            throw new IOError.FAILED("FileManager Tor onion S5B target did not expose a connection");
        }
    }

    private void wait_for_completion(ref bool completed_flag, ref MainLoop? target_loop, uint timeout_ms, string timeout_message) throws Error {
        if (!completed_flag) {
            bool timed_out = false;
            uint timeout_source = 0;
            MainLoop wait_loop = new MainLoop();
            target_loop = wait_loop;
            timeout_source = Timeout.add(timeout_ms, () => {
                timed_out = true;
                timeout_source = 0;
                wait_loop.quit();
                return Source.REMOVE;
            });
            wait_loop.run();
            target_loop = null;
            if (timeout_source != 0) {
                Source.remove(timeout_source);
            }
            if (timed_out && !completed_flag) {
                throw new IOError.TIMED_OUT(timeout_message);
            }
        }
    }

    private async void accept_warmup_once() throws Error {
        Object source_object;
        SocketConnection conn = yield listener.accept_async(null, out source_object);
        conn.close();
    }

    private async void accept_s5b_once() throws Error {
        Object source_object;
        SocketConnection conn = yield listener.accept_async(null, out source_object);
        try {
            yield handle_inner_s5b_connect(conn);
            connection = conn;
        } catch (Error e) {
            try {
                conn.close();
            } catch (Error close_error) {
            }
            throw e;
        }
    }

    private async void handle_inner_s5b_connect(SocketConnection conn) throws Error {
        string? dstaddr = expected_dstaddr;
        if (dstaddr == null) {
            throw new IOError.FAILED("FileManager Tor onion S5B target expected dstaddr was not set");
        }

        conn.socket.timeout = 2;
        size_t read;
        size_t written;
        uint8[] read_buffer = new uint8[1024];
        ByteArray write_buffer = new ByteArray();

        yield read_socks5_client_hello(conn, read_buffer);
        yield conn.output_stream.write_all_async({0x05, 0x00}, Priority.DEFAULT, null, out written);

        yield conn.input_stream.read_all_async(read_buffer[0:4], Priority.DEFAULT, null, out read);
        if (read != 4 || read_buffer[0] != 0x05 || read_buffer[1] != 0x01 || read_buffer[2] != 0x00 || read_buffer[3] != 0x03) {
            throw new IOError.PROXY_FAILED("FileManager Tor onion S5B target did not receive an inner domain CONNECT");
        }
        yield conn.input_stream.read_all_async(read_buffer[0:1], Priority.DEFAULT, null, out read);
        if (read != 1) {
            throw new IOError.PROXY_FAILED("FileManager Tor onion S5B target did not receive dstaddr length");
        }
        int dstaddr_len = read_buffer[0];
        yield conn.input_stream.read_all_async(read_buffer[0:dstaddr_len + 2], Priority.DEFAULT, null, out read);
        if (read != dstaddr_len + 2 ||
                dstaddr_len != ((!) dstaddr).length ||
                !Xmpp.Xep.JingleSocks5Bytestreams.bytes_equal(read_buffer[0:dstaddr_len], ((!) dstaddr).data) ||
                read_buffer[dstaddr_len] != 0x00 ||
                read_buffer[dstaddr_len + 1] != 0x00) {
            throw new IOError.PROXY_FAILED("FileManager Tor onion S5B target received an unexpected dstaddr");
        }

        write_buffer.append({0x05, 0x00, 0x00, 0x03});
        write_buffer.append({(uint8)((!) dstaddr).length});
        write_buffer.append(((!) dstaddr).data);
        write_buffer.append({0x00, 0x00});
        yield conn.output_stream.write_all_async(write_buffer.data, Priority.DEFAULT, null, out written);
        conn.socket.timeout = 0;
    }

    private async void read_socks5_client_hello(SocketConnection conn, uint8[] read_buffer) throws Error {
        size_t read;
        yield conn.input_stream.read_all_async(read_buffer[0:2], Priority.DEFAULT, null, out read);
        if (read != 2 || read_buffer[0] != 0x05 || read_buffer[1] == 0) {
            throw new IOError.PROXY_FAILED("FileManager Tor onion S5B target did not receive a valid client hello");
        }
        int num_auth_methods = read_buffer[1];
        yield conn.input_stream.read_all_async(read_buffer[0:num_auth_methods], Priority.DEFAULT, null, out read);
        bool found_null_auth = false;
        for (int i = 0; i < read; i++) {
            if (read_buffer[i] == 0x00) {
                found_null_auth = true;
                break;
            }
        }
        if (read != num_auth_methods || !found_null_auth) {
            throw new IOError.PROXY_FAILED("FileManager Tor onion S5B target did not receive null authentication support");
        }
    }

    public void close() {
        closed = true;
        listener.close();
        if (connection != null) {
            try {
                ((!) connection).close();
            } catch (Error e) {
            }
            connection = null;
        }
    }
}

private class FileManagerLocalTorSocksDaemon : Object {
    private string temp_dir;
    private string data_dir;
    private string torrc_path;
    private string log_path;
    private string? hidden_service_dir = null;
    private Subprocess? process = null;

    public int port { get; private set; }
    public string? onion_hostname { get; private set; default = null; }

    public static string? lookup_hidden_service_tor_path_or_skip() {
        if (Environment.get_variable("DINOX_TEST_REAL_TOR_HIDDEN_SERVICE_S5B") != "1") {
            GLib.Test.skip("Set DINOX_TEST_REAL_TOR_HIDDEN_SERVICE_S5B=1 to run the FileManager real Tor onion S5B receive-store proof");
            return null;
        }
        if (!GLib.Test.thorough()) {
            GLib.Test.skip("Run with -m thorough for the FileManager real Tor onion S5B receive-store proof");
            return null;
        }
        string? tor_path = lookup_tor_path();
        if (tor_path == null) {
            GLib.Test.skip("tor executable not found; skipping FileManager real Tor onion S5B receive-store proof");
            return null;
        }
        return tor_path;
    }

    public static FileManagerLocalTorSocksDaemon start_hidden_service(string tor_path, int target_port, int virtual_port) throws Error {
        return new FileManagerLocalTorSocksDaemon(tor_path, target_port, virtual_port);
    }

    private static string? lookup_tor_path() {
        string? tor_path = Environment.get_variable("DINOX_TEST_TOR_PATH");
        if (tor_path == null || ((!) tor_path).length == 0) {
            tor_path = Environment.find_program_in_path("tor");
        }
        return tor_path;
    }

    private FileManagerLocalTorSocksDaemon(string tor_path, int hidden_service_target_port, int hidden_service_virtual_port) throws Error {
        temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-manager-jingle-tor-" + Uuid.string_random());
        data_dir = Path.build_filename(temp_dir, "data");
        torrc_path = Path.build_filename(temp_dir, "empty-torrc");
        log_path = Path.build_filename(temp_dir, "tor.log");
        hidden_service_dir = Path.build_filename(temp_dir, "hidden-service");
        port = reserve_free_loopback_port();

        if (DirUtils.create_with_parents(data_dir, 0700) == -1) {
            throw new IOError.FAILED("Failed to create FileManager temporary Tor data directory");
        }
        if (DirUtils.create_with_parents((!) hidden_service_dir, 0700) == -1) {
            throw new IOError.FAILED("Failed to create FileManager temporary Tor hidden-service directory");
        }
        FileUtils.set_contents(torrc_path, "");

        string[] argv = {
            tor_path,
            "-f", torrc_path,
            "--DataDirectory", data_dir,
            "--SocksPort", "127.0.0.1:%d".printf(port),
            "--ControlPort", "0",
            "--CookieAuthentication", "0",
            "--SafeLogging", "0",
            "--HiddenServiceDir", (!) hidden_service_dir,
            "--HiddenServicePort", "%d 127.0.0.1:%d".printf(hidden_service_virtual_port, hidden_service_target_port),
            "--Log", "notice file " + log_path
        };
        try {
            process = new Subprocess.newv(argv, SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
            wait_until_ready();
            onion_hostname = wait_until_hidden_service_hostname(30000);
            wait_until_bootstrapped(180000);
        } catch (Error e) {
            close_process();
            delete_recursively(temp_dir);
            throw e;
        }
    }

    private static int reserve_free_loopback_port() throws Error {
        SocketListener listener = new SocketListener();
        InetSocketAddress addr = new InetSocketAddress.from_string("127.0.0.1", 0);
        SocketAddress effective_any;
        listener.add_address(addr, SocketType.STREAM, SocketProtocol.DEFAULT, null, out effective_any);
        InetSocketAddress effective = (InetSocketAddress) effective_any;
        int result = (int) effective.port;
        listener.close();
        return result;
    }

    private void wait_until_ready() throws Error {
        bool timed_out = false;
        uint timeout_source = 0;
        uint poll_source = 0;
        var loop = new MainLoop();

        poll_source = Timeout.add(10, () => {
            if (log_contains("Opened Socks listener connection (ready)")) {
                poll_source = 0;
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
        timeout_source = Timeout.add(3000, () => {
            timed_out = true;
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        if (timed_out && !log_contains("Opened Socks listener connection (ready)")) {
            throw new IOError.TIMED_OUT("Timed out starting FileManager Tor SOCKS listener: " + read_log_excerpt());
        }
    }

    private void wait_until_bootstrapped(uint timeout_ms) throws Error {
        bool timed_out = false;
        uint timeout_source = 0;
        uint poll_source = 0;
        var loop = new MainLoop();

        poll_source = Timeout.add(50, () => {
            if (log_contains("Bootstrapped 100% (done): Done")) {
                poll_source = 0;
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
        timeout_source = Timeout.add(timeout_ms, () => {
            timed_out = true;
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        if (timed_out && !log_contains("Bootstrapped 100% (done): Done")) {
            throw new IOError.TIMED_OUT("Timed out waiting for FileManager Tor bootstrap: " + read_log_excerpt());
        }
    }

    private string wait_until_hidden_service_hostname(uint timeout_ms) throws Error {
        string? service_dir = hidden_service_dir;
        if (service_dir == null) {
            throw new IOError.FAILED("FileManager Tor hidden-service directory is not configured");
        }
        string hostname_path = Path.build_filename((!) service_dir, "hostname");
        string? hostname = null;
        bool timed_out = false;
        uint timeout_source = 0;
        uint poll_source = 0;
        var loop = new MainLoop();

        poll_source = Timeout.add(50, () => {
            string contents;
            try {
                FileUtils.get_contents(hostname_path, out contents);
                string stripped = contents.strip();
                if (stripped.has_suffix(".onion")) {
                    hostname = stripped;
                    poll_source = 0;
                    loop.quit();
                    return Source.REMOVE;
                }
            } catch (Error e) {
            }
            return Source.CONTINUE;
        });
        timeout_source = Timeout.add(timeout_ms, () => {
            timed_out = true;
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (poll_source != 0) Source.remove(poll_source);
        if (timeout_source != 0) Source.remove(timeout_source);
        if (timed_out && hostname == null) {
            throw new IOError.TIMED_OUT("Timed out waiting for FileManager Tor hidden-service hostname: " + read_log_excerpt());
        }
        if (hostname == null) {
            throw new IOError.FAILED("FileManager Tor hidden-service hostname was not created");
        }
        return (!) hostname;
    }

    private bool log_contains(string needle) {
        string contents;
        try {
            FileUtils.get_contents(log_path, out contents);
        } catch (Error e) {
            return false;
        }
        return contents.contains(needle);
    }

    private string read_log_excerpt() {
        string contents;
        try {
            FileUtils.get_contents(log_path, out contents);
            return contents.substring(0, int.min(contents.length, 512));
        } catch (Error e) {
            return e.message;
        }
    }

    public void close() {
        close_process();
        delete_recursively(temp_dir);
    }

    private void close_process() {
        if (process == null) return;
        Subprocess proc = (!) process;
        process = null;
        proc.force_exit();
        try {
            proc.wait();
        } catch (Error e) {
        }
    }

    private static void delete_recursively(string path) {
        File file = File.new_for_path(path);
        try {
            FileType type = file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            if (type == FileType.DIRECTORY) {
                FileEnumerator enumerator = file.enumerate_children("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                FileInfo? info;
                while ((info = enumerator.next_file(null)) != null) {
                    delete_recursively(Path.build_filename(path, ((!) info).get_name()));
                }
                enumerator.close(null);
            }
            file.delete(null);
        } catch (Error e) {
        }
    }
}

private class FileManagerFakeOutboundSocksProxy : Object {
    private SocketListener listener = new SocketListener();
    private string? expected_target_host = null;
    private int expected_target_port = 0;
    private string? expected_dstaddr = null;
    private Error? failure = null;
    private bool completed = false;
    private MainLoop? loop = null;
    private SocketConnection? pending_connection = null;

    public int port { get; private set; }
    public SocketConnection? connection { get; private set; default = null; }

    public FileManagerFakeOutboundSocksProxy() throws Error {
        InetSocketAddress addr = new InetSocketAddress.from_string("127.0.0.1", 0);
        SocketAddress effective_any;
        listener.add_address(addr, SocketType.STREAM, SocketProtocol.DEFAULT, null, out effective_any);
        InetSocketAddress effective = (InetSocketAddress) effective_any;
        port = (int) effective.port;
        accept_once.begin((_, res) => {
            try {
                accept_once.end(res);
            } catch (Error e) {
                failure = e;
            }
            completed = true;
            if (loop != null) {
                ((!) loop).quit();
            }
        });
    }

    public void expect(string target_host, int target_port, string dstaddr) {
        expected_target_host = target_host;
        expected_target_port = target_port;
        expected_dstaddr = dstaddr;
    }

    public void wait_until_connected(uint timeout_ms) throws Error {
        if (!completed) {
            bool timed_out = false;
            uint timeout_source = 0;
            loop = new MainLoop();
            timeout_source = Timeout.add(timeout_ms, () => {
                timed_out = true;
                timeout_source = 0;
                if (loop != null) {
                    ((!) loop).quit();
                }
                return Source.REMOVE;
            });
            ((!) loop).run();
            loop = null;
            if (timeout_source != 0) {
                Source.remove(timeout_source);
            }
            if (timed_out && !completed) {
                throw new IOError.TIMED_OUT("Timed out waiting for FileManager outbound SOCKS proxy connection");
            }
        }
        if (failure != null) {
            throw (!) failure;
        }
        if (connection == null) {
            throw new IOError.FAILED("FileManager outbound SOCKS proxy did not expose a connection");
        }
    }

    private async void accept_once() throws Error {
        Object source_object;
        SocketConnection conn = yield listener.accept_async(null, out source_object);
        pending_connection = conn;
        try {
            yield handle_outer_socks_connect(conn);
            yield handle_inner_s5b_connect(conn);
            connection = conn;
            pending_connection = null;
        } catch (Error e) {
            try {
                conn.close();
            } catch (Error close_error) {
            }
            pending_connection = null;
            throw e;
        }
    }

    private async void handle_outer_socks_connect(SocketConnection conn) throws Error {
        conn.socket.timeout = 2;
        string? target_host = expected_target_host;
        string? dstaddr = expected_dstaddr;
        if (target_host == null || expected_target_port <= 0 || dstaddr == null) {
            throw new IOError.FAILED("FileManager outbound SOCKS proxy expectations were not set");
        }

        size_t read;
        size_t written;
        uint8[] read_buffer = new uint8[1024];

        yield read_socks5_client_hello(conn, read_buffer);
        yield conn.output_stream.write_all_async({0x05, 0x00}, Priority.DEFAULT, null, out written);

        yield conn.input_stream.read_all_async(read_buffer[0:4], Priority.DEFAULT, null, out read);
        if (read != 4 || read_buffer[0] != 0x05 || read_buffer[1] != 0x01 || read_buffer[2] != 0x00) {
            throw new IOError.PROXY_FAILED("FileManager outbound SOCKS proxy did not receive a valid CONNECT");
        }

        bool target_matches = false;
        uint8 atyp = read_buffer[3];
        if (atyp == 0x01) {
            yield conn.input_stream.read_all_async(read_buffer[0:6], Priority.DEFAULT, null, out read);
            int target_port = (((int) read_buffer[4]) << 8) | read_buffer[5];
            string actual_host = "%u.%u.%u.%u".printf(read_buffer[0], read_buffer[1], read_buffer[2], read_buffer[3]);
            target_matches = read == 6 && actual_host == (!) target_host && target_port == expected_target_port;
        } else if (atyp == 0x03) {
            yield conn.input_stream.read_all_async(read_buffer[0:1], Priority.DEFAULT, null, out read);
            if (read != 1) {
                throw new IOError.PROXY_FAILED("FileManager outbound SOCKS proxy did not receive target host length");
            }
            int host_len = read_buffer[0];
            yield conn.input_stream.read_all_async(read_buffer[0:host_len + 2], Priority.DEFAULT, null, out read);
            int target_port = (((int) read_buffer[host_len]) << 8) | read_buffer[host_len + 1];
            target_matches = read == host_len + 2 &&
                host_len == ((!) target_host).length &&
                Xmpp.Xep.JingleSocks5Bytestreams.bytes_equal(read_buffer[0:host_len], ((!) target_host).data) &&
                target_port == expected_target_port;
        } else {
            throw new IOError.PROXY_FAILED("FileManager outbound SOCKS proxy received an unsupported address type");
        }
        if (!target_matches) {
            throw new IOError.PROXY_FAILED("FileManager outbound SOCKS proxy received an unexpected target");
        }

        yield conn.output_stream.write_all_async({0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
            Priority.DEFAULT, null, out written);
    }

    private async void handle_inner_s5b_connect(SocketConnection conn) throws Error {
        string? dstaddr = expected_dstaddr;
        if (dstaddr == null) {
            throw new IOError.FAILED("FileManager outbound SOCKS proxy expected dstaddr was not set");
        }

        size_t read;
        size_t written;
        uint8[] read_buffer = new uint8[1024];
        ByteArray write_buffer = new ByteArray();

        yield read_socks5_client_hello(conn, read_buffer);
        yield conn.output_stream.write_all_async({0x05, 0x00}, Priority.DEFAULT, null, out written);

        yield conn.input_stream.read_all_async(read_buffer[0:4], Priority.DEFAULT, null, out read);
        if (read != 4 || read_buffer[0] != 0x05 || read_buffer[1] != 0x01 || read_buffer[2] != 0x00 || read_buffer[3] != 0x03) {
            throw new IOError.PROXY_FAILED("FileManager outbound SOCKS proxy did not receive an inner S5B domain CONNECT");
        }
        yield conn.input_stream.read_all_async(read_buffer[0:1], Priority.DEFAULT, null, out read);
        if (read != 1) {
            throw new IOError.PROXY_FAILED("FileManager outbound SOCKS proxy did not receive inner dstaddr length");
        }
        int dstaddr_len = read_buffer[0];
        yield conn.input_stream.read_all_async(read_buffer[0:dstaddr_len + 2], Priority.DEFAULT, null, out read);
        if (read != dstaddr_len + 2 ||
                dstaddr_len != ((!) dstaddr).length ||
                !Xmpp.Xep.JingleSocks5Bytestreams.bytes_equal(read_buffer[0:dstaddr_len], ((!) dstaddr).data) ||
                read_buffer[dstaddr_len] != 0x00 ||
                read_buffer[dstaddr_len + 1] != 0x00) {
            string actual_dstaddr = ((string) read_buffer[0:dstaddr_len]).make_valid().escape();
            throw new IOError.PROXY_FAILED(@"FileManager outbound SOCKS proxy received unexpected inner dstaddr $(actual_dstaddr), expected $((!) dstaddr)");
        }

        write_buffer.append({0x05, 0x00, 0x00, 0x03});
        write_buffer.append({(uint8)((!) dstaddr).length});
        write_buffer.append(((!) dstaddr).data);
        write_buffer.append({0x00, 0x00});
        yield conn.output_stream.write_all_async(write_buffer.data, Priority.DEFAULT, null, out written);
        conn.socket.timeout = 0;
    }

    private async void read_socks5_client_hello(SocketConnection conn, uint8[] read_buffer) throws Error {
        size_t read;
        yield conn.input_stream.read_all_async(read_buffer[0:2], Priority.DEFAULT, null, out read);
        if (read != 2 || read_buffer[0] != 0x05 || read_buffer[1] == 0) {
            throw new IOError.PROXY_FAILED("FileManager fake SOCKS proxy did not receive a valid client hello");
        }
        int num_auth_methods = read_buffer[1];
        yield conn.input_stream.read_all_async(read_buffer[0:num_auth_methods], Priority.DEFAULT, null, out read);
        bool found_null_auth = false;
        for (int i = 0; i < read; i++) {
            if (read_buffer[i] == 0x00) {
                found_null_auth = true;
                break;
            }
        }
        if (read != num_auth_methods || !found_null_auth) {
            throw new IOError.PROXY_FAILED("FileManager fake SOCKS proxy did not receive null authentication support");
        }
    }

    public void close() {
        listener.close();
        if (pending_connection != null) {
            try {
                ((!) pending_connection).close();
            } catch (Error e) {
            }
            pending_connection = null;
        }
        if (connection != null) {
            try {
                ((!) connection).close();
            } catch (Error e) {
            }
            connection = null;
        }
    }
}

private class FileManagerDirectConnectTrap : Object {
    private SocketListener listener = new SocketListener();
    private SocketConnection? connection = null;
    private Error? failure = null;
    private bool closed = false;

    public int port { get; private set; }

    public FileManagerDirectConnectTrap() throws Error {
        InetSocketAddress addr = new InetSocketAddress.from_string("127.0.0.1", 0);
        SocketAddress effective_any;
        listener.add_address(addr, SocketType.STREAM, SocketProtocol.DEFAULT, null, out effective_any);
        InetSocketAddress effective = (InetSocketAddress) effective_any;
        port = (int) effective.port;
        accept_once.begin((_, res) => {
            try {
                accept_once.end(res);
            } catch (Error e) {
                if (!closed) {
                    failure = e;
                }
            }
        });
    }

    public void assert_not_hit_after(uint timeout_ms) throws Error {
        uint timeout_source = 0;
        var loop = new MainLoop();
        timeout_source = Timeout.add(timeout_ms, () => {
            timeout_source = 0;
            loop.quit();
            return Source.REMOVE;
        });

        loop.run();

        if (timeout_source != 0) Source.remove(timeout_source);
        if (failure != null) {
            throw (!) failure;
        }
        if (connection != null) {
            throw new IOError.FAILED("FileManager S5B account-proxy path opened a direct remote-candidate connection");
        }
    }

    private async void accept_once() throws Error {
        Object source_object;
        connection = yield listener.accept_async(null, out source_object);
    }

    public void close() {
        closed = true;
        listener.close();
        if (connection != null) {
            try {
                ((!) connection).close();
            } catch (Error e) {
            }
            connection = null;
        }
    }
}

private class TestFailingFileDecryptor : Object, Dino.FileDecryptor {
    public bool called { get; private set; default = false; }
    public bool saw_decrypting_phase { get; private set; default = false; }

    public Dino.Entities.Encryption get_encryption() {
        return Dino.Entities.Encryption.PGP;
    }

    public Dino.FileReceiveData prepare_get_meta_info(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data) {
        return receive_data;
    }

    public Dino.FileMeta prepare_download_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) {
        return file_meta;
    }

    public bool can_decrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data) {
        return true;
    }

    public bool decrypts_before_return() {
        return true;
    }

    public async InputStream decrypt_file(InputStream encrypted_stream, Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data) throws Dino.FileReceiveError {
        called = true;
        saw_decrypting_phase = file_transfer.phase == Dino.Entities.FileTransfer.Phase.DECRYPTING;
        uint8[] buffer = new uint8[1];
        try {
            yield encrypted_stream.read_async(buffer, Priority.LOW, file_transfer.cancellable);
        } catch (Error e) {
        }
        throw new Dino.FileReceiveError.DECRYPTION_FAILED("synthetic decrypt failure");
    }
}

private class TestMimeOnlyFileDecryptor : Object, Dino.FileDecryptor {
    public int can_decrypt_calls { get; private set; default = 0; }
    public string? last_seen_mime_type { get; private set; default = null; }

    public Dino.Entities.Encryption get_encryption() {
        return Dino.Entities.Encryption.PGP;
    }

    public Dino.FileReceiveData prepare_get_meta_info(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data) {
        return receive_data;
    }

    public Dino.FileMeta prepare_download_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) {
        return file_meta;
    }

    public bool can_decrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data) {
        can_decrypt_calls++;
        last_seen_mime_type = file_transfer.mime_type;
        return file_transfer.mime_type == "application/pgp-encrypted";
    }

    public bool decrypts_before_return() {
        return true;
    }

    public async InputStream decrypt_file(InputStream encrypted_stream, Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data) throws Dino.FileReceiveError {
        throw new Dino.FileReceiveError.DECRYPTION_FAILED("synthetic MIME-only decryptor should not decrypt in this test");
    }
}

private class TestCapturingSuccessfulFileDecryptor : Object, Dino.FileDecryptor {
    public int prepare_conversation_type { get; private set; default = -1; }
    public int decrypt_conversation_type { get; private set; default = -1; }
    public string? prepare_counterpart { get; private set; default = null; }
    public string? decrypt_counterpart { get; private set; default = null; }
    public bool decrypt_called { get; private set; default = false; }
    private string plaintext;

    public TestCapturingSuccessfulFileDecryptor(string plaintext) {
        this.plaintext = plaintext;
    }

    public Dino.Entities.Encryption get_encryption() {
        return Dino.Entities.Encryption.PGP;
    }

    public Dino.FileReceiveData prepare_get_meta_info(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data) {
        return receive_data;
    }

    public Dino.FileMeta prepare_download_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) {
        prepare_conversation_type = (int) conversation.type_;
        prepare_counterpart = conversation.counterpart.to_string();
        file_meta.file_name = "payload.txt";
        file_meta.mime_type = "text/plain";
        return file_meta;
    }

    public bool can_decrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data) {
        return file_transfer.encryption == Dino.Entities.Encryption.PGP ||
            file_transfer.mime_type == "application/pgp-encrypted";
    }

    public bool decrypts_before_return() {
        return true;
    }

    public async InputStream decrypt_file(InputStream encrypted_stream, Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data) throws Dino.FileReceiveError {
        decrypt_called = true;
        decrypt_conversation_type = (int) conversation.type_;
        decrypt_counterpart = conversation.counterpart.to_string();
        return new MemoryInputStream.from_data(plaintext.data);
    }
}

private class TestPlainIncomingProvider : Object, Dino.FileProvider {
    protected int provider_id;
    public bool download_called { get; protected set; default = false; }
    public bool source_available { get; set; default = true; }

    public TestPlainIncomingProvider(int provider_id) {
        this.provider_id = provider_id;
    }

    public virtual Dino.Entities.Encryption get_encryption(Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) {
        return Dino.Entities.Encryption.NONE;
    }

    public virtual Dino.FileMeta get_file_meta(Dino.Entities.FileTransfer file_transfer) throws Dino.FileReceiveError {
        var file_meta = new Dino.FileMeta();
        file_meta.file_name = file_transfer.file_name;
        file_meta.mime_type = file_transfer.mime_type;
        file_meta.size = file_transfer.size;
        return file_meta;
    }

    public virtual Dino.FileReceiveData? get_file_receive_data(Dino.Entities.FileTransfer file_transfer) {
        if (!source_available) return null;
        return new Dino.FileReceiveData();
    }

    public virtual bool has_usable_download_source(Dino.Entities.FileTransfer file_transfer) {
        return source_available;
    }

    public virtual async Dino.FileMeta get_meta_info(Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) throws Dino.FileReceiveError, IOError {
        return file_meta;
    }

    public virtual async InputStream download(Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) throws IOError {
        download_called = true;
        return new MemoryInputStream.from_data("unused".data);
    }

    public virtual int get_id() {
        return provider_id;
    }
}

private class TestFailOnceIncomingProvider : TestPlainIncomingProvider {
    private uint8[] payload;
    private string? timeout_message;
    public int download_attempts { get; private set; default = 0; }

    public TestFailOnceIncomingProvider(int provider_id, uint8[] payload, string? timeout_message = null) {
        base(provider_id);
        this.payload = payload;
        this.timeout_message = timeout_message;
    }

    public override async InputStream download(Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) throws IOError {
        download_called = true;
        download_attempts++;
        if (download_attempts == 1) {
            if (timeout_message != null) throw new IOError.TIMED_OUT(timeout_message);
            throw new IOError.FAILED("HTTP download failed: status 404");
        }
        return new MemoryInputStream.from_data(payload);
    }
}

private class TestLateMimeMetadataProvider : TestPlainIncomingProvider {
    public bool metadata_called { get; protected set; default = false; }

    public TestLateMimeMetadataProvider(int provider_id) {
        base(provider_id);
    }

    public override Dino.FileMeta get_file_meta(Dino.Entities.FileTransfer file_transfer) throws Dino.FileReceiveError {
        var file_meta = new Dino.FileMeta();
        file_meta.file_name = file_transfer.file_name;
        file_meta.size = -1;
        return file_meta;
    }

    public override async Dino.FileMeta get_meta_info(Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) throws Dino.FileReceiveError, IOError {
        metadata_called = true;
        file_meta.file_name = "payload";
        file_meta.mime_type = "application/pgp-encrypted";
        file_meta.size = 4096;
        return file_meta;
    }
}

private class TestLateProviderEncryptionMetadataProvider : TestLateMimeMetadataProvider {
    public TestLateProviderEncryptionMetadataProvider(int provider_id) {
        base(provider_id);
    }

    public override Dino.Entities.Encryption get_encryption(Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) {
        return file_meta.mime_type == "application/pgp-encrypted" ? Dino.Entities.Encryption.PGP : Dino.Entities.Encryption.NONE;
    }

    public override async Dino.FileMeta get_meta_info(Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) throws Dino.FileReceiveError, IOError {
        metadata_called = true;
        file_meta.file_name = "payload";
        file_meta.mime_type = "application/pgp-encrypted";
        file_meta.size = 4096;
        file_meta.encryption_protocol = "late-pgp-protocol";
        return file_meta;
    }
}

private class TestCancellingMetadataProvider : Object, Dino.FileProvider {
    public bool metadata_called { get; private set; default = false; }
    public bool download_called { get; private set; default = false; }

    public Dino.Entities.Encryption get_encryption(Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) {
        return Dino.Entities.Encryption.NONE;
    }

    public Dino.FileMeta get_file_meta(Dino.Entities.FileTransfer file_transfer) throws Dino.FileReceiveError {
        var file_meta = new Dino.FileMeta();
        file_meta.file_name = file_transfer.file_name;
        file_meta.mime_type = file_transfer.mime_type;
        file_meta.size = -1;
        return file_meta;
    }

    public Dino.FileReceiveData? get_file_receive_data(Dino.Entities.FileTransfer file_transfer) {
        return new Dino.FileReceiveData();
    }

    public bool has_usable_download_source(Dino.Entities.FileTransfer file_transfer) {
        return true;
    }

    public async Dino.FileMeta get_meta_info(Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) throws Dino.FileReceiveError, IOError {
        metadata_called = true;
        file_meta.file_name = "server-name.bin";
        file_meta.mime_type = "application/test";
        file_meta.size = 2048;
        file_transfer.cancellable.cancel();
        throw new IOError.CANCELLED("synthetic metadata cancellation");
    }

    public async InputStream download(Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) throws IOError {
        download_called = true;
        return new MemoryInputStream.from_data("unexpected download".data);
    }

    public int get_id() {
        return 99;
    }
}

private class TestStreamingFailingFileDecryptor : Object, Dino.FileDecryptor {
    public bool called { get; private set; default = false; }
    private uint8[] plaintext_prefix;

    public TestStreamingFailingFileDecryptor(uint8[] plaintext_prefix) {
        this.plaintext_prefix = plaintext_prefix;
    }

    public Dino.Entities.Encryption get_encryption() {
        return Dino.Entities.Encryption.OMEMO;
    }

    public Dino.FileReceiveData prepare_get_meta_info(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data) {
        return receive_data;
    }

    public Dino.FileMeta prepare_download_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data, Dino.FileMeta file_meta) {
        return file_meta;
    }

    public bool can_decrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data) {
        return true;
    }

    public bool decrypts_before_return() {
        return false;
    }

    public async InputStream decrypt_file(InputStream encrypted_stream, Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileReceiveData receive_data) throws Dino.FileReceiveError {
        called = true;
        return new TestPartialFailingInputStream(plaintext_prefix);
    }
}

private class TestPartialFailingInputStream : InputStream {
    private uint8[] data;
    private int offset = 0;
    private bool failed = false;

    public TestPartialFailingInputStream(uint8[] data) {
        this.data = data;
    }

    public override ssize_t read(uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        if (failed) {
            throw new IOError.FAILED("synthetic streaming auth failure");
        }

        if (offset < data.length) {
            int remaining = data.length - offset;
            int count = int.min(buffer.length, remaining);
            Memory.copy(buffer, (void*) ((uint8*) data + offset), count);
            offset += count;
            return count;
        }

        failed = true;
        throw new IOError.FAILED("synthetic streaming auth failure");
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        return true;
    }
}

private class DeterministicLargeInputStream : InputStream {
    private int64 total_size;
    private int64 offset = 0;

    public int read_calls { get; private set; default = 0; }
    public int max_requested { get; private set; default = 0; }
    public int max_returned { get; private set; default = 0; }

    public DeterministicLargeInputStream(int64 total_size) {
        this.total_size = total_size;
    }

    public static uint8 pattern_byte_at(int64 position) {
        return (uint8) ((position * 31 + 7) % 251);
    }

    public override ssize_t read(uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) {
            cancellable.set_error_if_cancelled();
        }
        if (offset >= total_size) return 0;

        read_calls++;
        if (buffer.length > max_requested) max_requested = buffer.length;
        int64 remaining = total_size - offset;
        int count = remaining < buffer.length ? (int) remaining : buffer.length;
        if (count > max_returned) max_returned = count;

        for (int i = 0; i < count; i++) {
            buffer[i] = pattern_byte_at(offset + i);
        }
        offset += count;
        return count;
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        return true;
    }
}

private class TestAsyncOnlyInputStream : InputStream {
    private uint8[] data;
    private int offset = 0;
    private bool closed = false;
    public bool read_async_called { get; private set; default = false; }

    public TestAsyncOnlyInputStream(uint8[] data) {
        this.data = data;
    }

    public override ssize_t read(uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        throw new IOError.NOT_SUPPORTED("synthetic async-only stream");
    }

    public override async ssize_t read_async(uint8[]? buffer, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        read_async_called = true;
        SourceFunc callback = read_async.callback;
        Idle.add((owned) callback, io_priority);
        yield;

        if (cancellable != null) {
            cancellable.set_error_if_cancelled();
        }
        if (closed || buffer == null || offset >= data.length) {
            return 0;
        }

        int remaining = data.length - offset;
        int count = int.min(((!) buffer).length, remaining);
        Memory.copy((!) buffer, (void*) ((uint8*) data + offset), count);
        offset += count;
        return count;
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        throw new IOError.NOT_SUPPORTED("synthetic async-only stream");
    }

    public override async bool close_async(int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        closed = true;
        return true;
    }
}

private class TestBlockingAsyncOnlyInputStream : InputStream {
    private bool closed = false;
    public bool read_async_called { get; private set; default = false; }

    public signal void read_started();

    public override ssize_t read(uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        throw new IOError.NOT_SUPPORTED("synthetic async-only stream");
    }

    public override async ssize_t read_async(uint8[]? buffer, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        read_async_called = true;
        SourceFunc callback = read_async.callback;
        ulong cancel_id = 0;
        if (cancellable != null) {
            if (cancellable.is_cancelled()) {
                throw new IOError.CANCELLED("synthetic async-only stream cancelled");
            }
            cancel_id = cancellable.connect(() => {
                Idle.add((owned) callback, io_priority);
            });
        }

        read_started();
        yield;
        if (cancellable != null && cancel_id != 0) {
            cancellable.disconnect(cancel_id);
        }
        if (closed) return 0;
        if (cancellable != null) {
            cancellable.set_error_if_cancelled();
        }
        return 0;
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        throw new IOError.NOT_SUPPORTED("synthetic async-only stream");
    }

    public override async bool close_async(int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        closed = true;
        return true;
    }
}

private class TestFileEncryptor : Object, Dino.FileEncryptor {
    public bool can_encrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return true;
    }

    public async Dino.FileMeta encrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) throws Dino.FileSendError {
        return new Dino.FileMeta();
    }

    public Dino.FileSendData? preprocess_send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileSendData file_send_data, Dino.FileMeta file_meta) throws Dino.FileSendError {
        return file_send_data;
    }
}

private class TestRequiredSenderFileEncryptor : Object, Dino.FileEncryptor, Dino.FileEncryptorSenderRequirement {
    private int required_sender_id;

    public TestRequiredSenderFileEncryptor(int required_sender_id) {
        this.required_sender_id = required_sender_id;
    }

    public bool can_encrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return true;
    }

    public int get_required_file_sender_id() {
        return required_sender_id;
    }

    public async Dino.FileMeta encrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) throws Dino.FileSendError {
        var meta = new Dino.FileMeta();
        meta.upload_payload_is_encrypted = true;
        return meta;
    }

    public Dino.FileSendData? preprocess_send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileSendData file_send_data, Dino.FileMeta file_meta) throws Dino.FileSendError {
        return file_send_data;
    }
}

private class TestRejectingFileEncryptor : Object, Dino.FileEncryptor, Dino.FileEncryptorRejectionReason {
    private Dino.Entities.Encryption encryption;
    private string rejection_reason;
    public bool can_encrypt_called { get; private set; default = false; }
    public bool rejection_reason_called { get; private set; default = false; }
    public bool encrypt_called { get; private set; default = false; }

    public TestRejectingFileEncryptor(Dino.Entities.Encryption encryption, string rejection_reason) {
        this.encryption = encryption;
        this.rejection_reason = rejection_reason;
    }

    public bool can_encrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        can_encrypt_called = true;
        return false;
    }

    public string? get_file_encryption_rejection_reason(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        rejection_reason_called = true;
        return file_transfer.encryption == encryption ? rejection_reason : null;
    }

    public async Dino.FileMeta encrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) throws Dino.FileSendError {
        encrypt_called = true;
        return new Dino.FileMeta();
    }

    public Dino.FileSendData? preprocess_send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileSendData file_send_data, Dino.FileMeta file_meta) throws Dino.FileSendError {
        return file_send_data;
    }
}

private class TestRecordingFileSender : Object, Dino.FileSender {
    private bool encrypts_payload;
    private bool returns_http_send_data;
    private bool read_payload;
    private int sender_id;
    private float priority;
    public bool prepare_called { get; private set; default = false; }
    public int64 prepare_meta_size { get; private set; default = -1; }
    public bool prepare_meta_upload_payload_is_encrypted { get; private set; default = false; }
    public bool send_called { get; private set; default = false; }
    public int64 send_meta_size { get; private set; default = -1; }
    public bool send_meta_upload_payload_is_encrypted { get; private set; default = false; }
    public bool send_data_is_http { get; private set; default = false; }
    public bool send_data_encrypt_message { get; private set; default = false; }
    public string? send_data_url_down { get; private set; default = null; }
    public uint8[]? uploaded_payload = null;

    public TestRecordingFileSender(bool encrypts_payload = false, bool returns_http_send_data = false, bool read_payload = false,
            int sender_id = Dino.FileManager.HTTP_PROVIDER_ID, float priority = 100) {
        this.encrypts_payload = encrypts_payload;
        this.returns_http_send_data = returns_http_send_data;
        this.read_payload = read_payload;
        this.sender_id = sender_id;
        this.priority = priority;
    }

    public async bool is_upload_available(Dino.Entities.Conversation conversation) {
        return true;
    }

    public async long get_file_size_limit(Dino.Entities.Conversation conversation) {
        return long.MAX;
    }

    public async bool can_send(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return true;
    }

    public async Dino.FileSendData? prepare_send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileMeta file_meta) throws Dino.FileSendError {
        prepare_called = true;
        prepare_meta_size = file_meta.size;
        prepare_meta_upload_payload_is_encrypted = file_meta.upload_payload_is_encrypted;
        if (returns_http_send_data) {
            return new Dino.HttpFileSendData() {
                url_down = "https://upload.example.test/payload.bin",
                url_up = "https://upload.example.test/put/payload.bin",
                headers = new Gee.HashMap<string, string>(),
                encrypt_message = false
            };
        }
        return new Dino.FileSendData();
    }

    public async void send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileSendData file_send_data, Dino.FileMeta file_meta) throws Dino.FileSendError {
        send_called = true;
        send_meta_size = file_meta.size;
        send_meta_upload_payload_is_encrypted = file_meta.upload_payload_is_encrypted;
        Dino.HttpFileSendData? http_send_data = file_send_data as Dino.HttpFileSendData;
        send_data_is_http = http_send_data != null;
        if (http_send_data != null) {
            send_data_encrypt_message = ((!) http_send_data).encrypt_message;
            send_data_url_down = ((!) http_send_data).url_down;
        }
        if (read_payload) {
            try {
                var output = new MemoryOutputStream.resizable();
                uint8[] buffer = new uint8[4096];
                ssize_t read = 0;
                while ((read = file_transfer.input_stream.read(buffer)) > 0) {
                    output.write(buffer[0:(int) read]);
                }
                output.close();
                uint8[] payload = output.steal_data();
                payload.length = (int) output.get_data_size();
                uploaded_payload = payload;
            } catch (Error e) {
                throw new Dino.FileSendError.UPLOAD_FAILED(e.message);
            }
        }
    }

    public async bool can_encrypt(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return encrypts_payload;
    }

    public int get_id() {
        return sender_id;
    }

    public float get_priority() {
        return priority;
    }
}

private class TestBlockingAvailabilityFileSender : Object, Dino.FileSender {
    private int sender_id;
    private float priority;
    private long limit;
    private SourceFunc? resume_probe = null;

    public bool probe_started { get; private set; default = false; }
    public int limit_probe_count { get; private set; default = 0; }
    public int can_send_count { get; private set; default = 0; }

    public TestBlockingAvailabilityFileSender(int sender_id, float priority, long limit) {
        this.sender_id = sender_id;
        this.priority = priority;
        this.limit = limit;
    }

    public async bool is_upload_available(Dino.Entities.Conversation conversation) {
        return true;
    }

    public async long get_file_size_limit(Dino.Entities.Conversation conversation) {
        limit_probe_count++;
        return limit;
    }

    public void release() {
        if (resume_probe == null) return;
        SourceFunc callback = (owned) resume_probe;
        Idle.add((owned) callback);
    }

    public async bool can_send(Dino.Entities.Conversation conversation,
            Dino.Entities.FileTransfer file_transfer) {
        can_send_count++;
        probe_started = true;
        resume_probe = can_send.callback;
        yield;
        return true;
    }

    public async Dino.FileSendData? prepare_send_file(Dino.Entities.Conversation conversation,
            Dino.Entities.FileTransfer file_transfer, Dino.FileMeta file_meta) throws Dino.FileSendError {
        return new Dino.FileSendData();
    }

    public async void send_file(Dino.Entities.Conversation conversation,
            Dino.Entities.FileTransfer file_transfer, Dino.FileSendData file_send_data,
            Dino.FileMeta file_meta) throws Dino.FileSendError {
    }

    public async bool can_encrypt(Dino.Entities.Conversation conversation,
            Dino.Entities.FileTransfer file_transfer) {
        return false;
    }

    public int get_id() {
        return sender_id;
    }

    public float get_priority() {
        return priority;
    }
}

private class TestPendingTransportSend : Object {
    public Dino.Entities.FileTransfer transfer { get; private set; }
    private SourceFunc? resume_callback;

    public TestPendingTransportSend(Dino.Entities.FileTransfer transfer, owned SourceFunc resume_callback) {
        this.transfer = transfer;
        this.resume_callback = (owned) resume_callback;
    }

    public void resume() {
        if (resume_callback == null) return;
        SourceFunc? callback = (owned) resume_callback;
        if (callback != null) Idle.add((owned) callback);
    }
}

private class TestControlledFileSender : Object, Dino.FileSender {
    private int sender_id;
    private float priority;
    private Gee.ArrayList<TestPendingTransportSend> pending = new Gee.ArrayList<TestPendingTransportSend>();
    private Gee.HashMap<string, Bytes> payloads = new Gee.HashMap<string, Bytes>();

    public int active_count { get { return pending.size; } }

    public TestControlledFileSender(int sender_id, float priority) {
        this.sender_id = sender_id;
        this.priority = priority;
    }

    public async bool is_upload_available(Dino.Entities.Conversation conversation) {
        return true;
    }

    public async long get_file_size_limit(Dino.Entities.Conversation conversation) {
        return long.MAX;
    }

    public async bool can_send(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return true;
    }

    public async Dino.FileSendData? prepare_send_file(Dino.Entities.Conversation conversation,
            Dino.Entities.FileTransfer file_transfer, Dino.FileMeta file_meta) throws Dino.FileSendError {
        return new Dino.FileSendData();
    }

    public async void send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer,
            Dino.FileSendData file_send_data, Dino.FileMeta file_meta) throws Dino.FileSendError {
        SourceFunc callback = send_file.callback;
        var pending_send = new TestPendingTransportSend(file_transfer, (owned) callback);
        pending.add(pending_send);
        ulong cancel_id = file_transfer.cancellable.connect(() => pending_send.resume());
        yield;
        if (cancel_id != 0) file_transfer.cancellable.disconnect(cancel_id);
        pending.remove(pending_send);

        if (file_transfer.cancellable.is_cancelled()) return;
        try {
            var output = new MemoryOutputStream.resizable();
            uint8[] buffer = new uint8[4096];
            ssize_t read = 0;
            while ((read = file_transfer.input_stream.read(buffer)) > 0) {
                output.write(buffer[0:(int) read]);
            }
            output.close();
            uint8[] payload = output.steal_data();
            payload.length = (int) output.get_data_size();
            payloads[conversation.counterpart.to_string()] = new Bytes(payload);
        } catch (Error e) {
            throw new Dino.FileSendError.UPLOAD_FAILED(e.message);
        }
    }

    public void release(Dino.Entities.FileTransfer transfer) {
        foreach (TestPendingTransportSend pending_send in pending) {
            if (pending_send.transfer == transfer) {
                pending_send.resume();
                return;
            }
        }
    }

    public bool is_active(Dino.Entities.FileTransfer transfer) {
        foreach (TestPendingTransportSend pending_send in pending) {
            if (pending_send.transfer == transfer) return true;
        }
        return false;
    }

    public bool has_payload(Xmpp.Jid counterpart, uint8[] expected) {
        Bytes? payload = payloads[counterpart.to_string()];
        if (payload == null) return false;
        unowned uint8[] actual = ((!) payload).get_data();
        if (actual.length != expected.length) return false;
        for (int i = 0; i < expected.length; i++) {
            if (actual[i] != expected[i]) return false;
        }
        return true;
    }

    public async bool can_encrypt(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return false;
    }

    public int get_id() {
        return sender_id;
    }

    public float get_priority() {
        return priority;
    }
}

private class TestUnavailableFileSender : Object, Dino.FileSender {
    private int sender_id;
    private float priority;
    public bool can_send_called { get; private set; default = false; }

    public TestUnavailableFileSender(int sender_id = Dino.FileManager.HTTP_PROVIDER_ID, float priority = 100) {
        this.sender_id = sender_id;
        this.priority = priority;
    }
    public bool prepare_called { get; private set; default = false; }
    public bool send_called { get; private set; default = false; }

    public async bool is_upload_available(Dino.Entities.Conversation conversation) {
        return true;
    }

    public async long get_file_size_limit(Dino.Entities.Conversation conversation) {
        return long.MAX;
    }

    public async bool can_send(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        can_send_called = true;
        return false;
    }

    public async Dino.FileSendData? prepare_send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileMeta file_meta) throws Dino.FileSendError {
        prepare_called = true;
        return new Dino.FileSendData();
    }

    public async void send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileSendData file_send_data, Dino.FileMeta file_meta) throws Dino.FileSendError {
        send_called = true;
    }

    public async bool can_encrypt(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return false;
    }

    public int get_id() {
        return sender_id;
    }

    public float get_priority() {
        return priority;
    }
}

private class TestRecordingFileEncryptor : Object, Dino.FileEncryptor, Dino.FileEncryptorSenderRequirement {
    private int64 encrypted_size;
    private bool marks_payload_encrypted;
    public bool encrypt_called { get; private set; default = false; }

    public TestRecordingFileEncryptor(int64 encrypted_size, bool marks_payload_encrypted) {
        this.encrypted_size = encrypted_size;
        this.marks_payload_encrypted = marks_payload_encrypted;
    }

    public bool can_encrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return file_transfer.encryption == Dino.Entities.Encryption.PGP ||
            file_transfer.encryption == Dino.Entities.Encryption.OMEMO;
    }

    public int get_required_file_sender_id() {
        return Dino.FileManager.HTTP_PROVIDER_ID;
    }

    public async Dino.FileMeta encrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) throws Dino.FileSendError {
        encrypt_called = true;
        var meta = new Dino.FileMeta();
        meta.size = encrypted_size;
        meta.mime_type = "application/pgp-encrypted";
        meta.upload_payload_is_encrypted = marks_payload_encrypted;
        return meta;
    }

    public Dino.FileSendData? preprocess_send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileSendData file_send_data, Dino.FileMeta file_meta) throws Dino.FileSendError {
        return file_send_data;
    }
}

private class TestHttpSendDataFileEncryptor : Object, Dino.FileEncryptor, Dino.FileEncryptorSenderRequirement {
    private Dino.Entities.Encryption encryption;
    private int64 encrypted_size;
    public bool preprocess_called { get; private set; default = false; }

    public TestHttpSendDataFileEncryptor(Dino.Entities.Encryption encryption, int64 encrypted_size) {
        this.encryption = encryption;
        this.encrypted_size = encrypted_size;
    }

    public bool can_encrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return file_transfer.encryption == encryption;
    }

    public int get_required_file_sender_id() {
        return Dino.FileManager.HTTP_PROVIDER_ID;
    }

    public async Dino.FileMeta encrypt_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) throws Dino.FileSendError {
        var meta = new Dino.FileMeta();
        meta.size = encrypted_size;
        meta.mime_type = encryption == Dino.Entities.Encryption.PGP ? "application/pgp-encrypted" : "application/octet-stream";
        meta.encryption = encryption;
        meta.upload_payload_is_encrypted = true;
        return meta;
    }

    public Dino.FileSendData? preprocess_send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileSendData file_send_data, Dino.FileMeta file_meta) throws Dino.FileSendError {
        preprocess_called = true;
        Dino.HttpFileSendData? http_send_data = file_send_data as Dino.HttpFileSendData;
        if (http_send_data == null) return null;
        ((!) http_send_data).encrypt_message = true;
        return file_send_data;
    }
}

private class TestFailingFileSender : Object, Dino.FileSender {
    private string error_message;
    public bool prepare_called { get; private set; default = false; }
    public bool send_called { get; private set; default = false; }

    public TestFailingFileSender(string error_message) {
        this.error_message = error_message;
    }

    public async bool is_upload_available(Dino.Entities.Conversation conversation) {
        return true;
    }

    public async long get_file_size_limit(Dino.Entities.Conversation conversation) {
        return long.MAX;
    }

    public async bool can_send(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return true;
    }

    public async Dino.FileSendData? prepare_send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileMeta file_meta) throws Dino.FileSendError {
        prepare_called = true;
        return new Dino.FileSendData();
    }

    public async void send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileSendData file_send_data, Dino.FileMeta file_meta) throws Dino.FileSendError {
        send_called = true;
        throw new Dino.FileSendError.UPLOAD_FAILED(error_message);
    }

    public async bool can_encrypt(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return false;
    }

    public int get_id() {
        return Dino.FileManager.HTTP_PROVIDER_ID;
    }

    public float get_priority() {
        return 200;
    }
}

private class TestCancellingFileSender : Object, Dino.FileSender {
    private float priority;
    public bool prepare_called { get; private set; default = false; }
    public bool send_called { get; private set; default = false; }

    public TestCancellingFileSender(float priority = 200) {
        this.priority = priority;
    }

    public async bool is_upload_available(Dino.Entities.Conversation conversation) {
        return true;
    }

    public async long get_file_size_limit(Dino.Entities.Conversation conversation) {
        return long.MAX;
    }

    public async bool can_send(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return true;
    }

    public async Dino.FileSendData? prepare_send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileMeta file_meta) throws Dino.FileSendError {
        prepare_called = true;
        file_transfer.cancellable.cancel();
        return new Dino.FileSendData();
    }

    public async void send_file(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer, Dino.FileSendData file_send_data, Dino.FileMeta file_meta) throws Dino.FileSendError {
        send_called = true;
    }

    public async bool can_encrypt(Dino.Entities.Conversation conversation, Dino.Entities.FileTransfer file_transfer) {
        return false;
    }

    public int get_id() {
        return Dino.FileManager.HTTP_PROVIDER_ID;
    }

    public float get_priority() {
        return priority;
    }
}

}
