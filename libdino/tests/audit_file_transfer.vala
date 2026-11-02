namespace Dino.Test {

/**
 * Security Audit: FileTransfer.file_name sanitization
 *
 * The file_name setter strips path components and prevents:
 *   - Path traversal attacks (../../etc/passwd)
 *   - Hidden file creation (.ssh/authorized_keys)
 *   - Empty/separator-only filenames
 */
class FileTransferAudit : Gee.TestCase {

    public FileTransferAudit() {
        base("FileTransferAudit");

        // --- file_name sanitization ---
        add_test("PathTraversal_dotdot_stripped", test_path_traversal);
        add_test("PathTraversal_absolute_path_stripped", test_absolute_path);
        add_test("HiddenFile_dot_prefix_guarded", test_hidden_file);
        add_test("HiddenFile_dotdot_special", test_dotdot_name);
        add_test("Separator_only_becomes_unknown", test_separator_only);
        add_test("Dot_only_becomes_unknown", test_dot_only);
        add_test("Windows_path_stripped", test_windows_path);
        add_test("Invalid_windows_chars_replaced", test_invalid_windows_chars);
        add_test("Control_chars_replaced", test_control_chars);
        add_test("Image_filename_fallback", test_image_filename_fallback);
        add_test("Svg_filename_not_previewed", test_svg_filename_not_previewed);
        add_test("Normal_filename_preserved", test_normal_filename);
        add_test("Filename_with_spaces_preserved", test_filename_spaces);
        add_test("Phase_active_resets_progress", test_phase_active_resets_progress);
        add_test("Phase_notify_exposes_reset_progress", test_phase_notify_exposes_reset_progress);
        add_test("Phase_complete_sets_terminal_progress", test_phase_complete_sets_terminal_progress);
        add_test("Phase_none_resets_to_not_started", test_phase_none_resets_to_not_started);
        add_test("Phase_failed_keeps_error", test_phase_failed_keeps_error);
        add_test("Persistent_state_never_writes_in_progress", test_persistent_state_never_writes_in_progress);
        add_test("Restart_recovery_marks_legacy_in_progress_failed", test_restart_recovery_marks_legacy_in_progress_failed);
        add_test("Database_removes_orphaned_content_items", test_database_removes_orphaned_content_items);
        add_test("Transfer_attempt_replaces_cancelled_cancellable", test_transfer_attempt_replaces_cancelled_cancellable);
        add_test("Plaintext_release_requires_complete_transfer", test_plaintext_release_requires_complete_transfer);
        add_test("Prepared_meta_updates_safe_transfer_fields", test_prepared_meta_updates_safe_transfer_fields);
        add_test("Prepared_meta_ignores_missing_fields", test_prepared_meta_ignores_missing_fields);
        add_test("Provider_meta_updates_transport_size", test_provider_meta_updates_transport_size);
        add_test("Receive_encryption_classification_provider_wins", test_receive_encryption_classification_provider_wins);
        add_test("Receive_encryption_classification_uses_decryptor_fallback", test_receive_encryption_classification_uses_decryptor_fallback);
        add_test("Receive_store_phase_matches_pipeline_kind", test_receive_store_phase_matches_pipeline_kind);
        add_test("Receive_attempt_only_starts_from_idle_or_failed", test_receive_attempt_only_starts_from_idle_or_failed);
        add_test("Send_retry_requires_failed_sent_local_copy", test_send_retry_requires_failed_sent_local_copy);
        add_test("Message_relation_prefers_explicit_id_and_keeps_legacy_fallback", test_message_relation_prefers_explicit_id_and_keeps_legacy_fallback);
        add_test("Database_v50_migration_backfills_only_canonical_message_relations", test_database_v50_migration_backfills_only_canonical_message_relations);
        add_test("Live_message_relation_updates_storage_cache", test_live_message_relation_updates_storage_cache);
        add_test("Sfs_download_source_missing_until_source_arrives", test_sfs_download_source_missing_until_source_arrives);
        add_test("Sfs_pending_sources_replayed_when_share_arrives", test_sfs_pending_sources_replayed_when_share_arrives);
        add_test("Sfs_plain_http_usable_for_unencrypted_transfer", test_sfs_plain_http_usable_for_unencrypted_transfer);
        add_test("Sfs_plain_http_rejected_for_encrypted_transfer", test_sfs_plain_http_rejected_for_encrypted_transfer);
        add_test("Sfs_esfs_valid_gcm_for_encrypted_transfer", test_sfs_esfs_valid_gcm_for_encrypted_transfer);
        add_test("Sfs_esfs_rejects_wrong_key_length", test_sfs_esfs_rejects_wrong_key_length);
        add_test("Sfs_esfs_rejects_wrong_iv_length", test_sfs_esfs_rejects_wrong_iv_length);
        add_test("Sfs_esfs_rejects_cbc_without_hash_context", test_sfs_esfs_rejects_cbc_without_hash_context);
        add_test("Sfs_esfs_rejects_unknown_and_substring_ciphers", test_sfs_esfs_rejects_unknown_and_substring_ciphers);
        add_test("Sfs_invalid_esfs_rejected_for_encrypted_transfer", test_sfs_invalid_esfs_rejected_for_encrypted_transfer);
        add_test("Sfs_sent_and_legacy_transfers_stay_usable", test_sfs_sent_and_legacy_transfers_stay_usable);
        add_test("Transient_provider_source_requires_live_offer", test_transient_provider_source_requires_live_offer);
        add_test("Sfs_auto_download_requires_usable_source", test_sfs_auto_download_requires_usable_source);
    }

    private const int TEST_SFS_PROVIDER_ID = 2;
    private const int TEST_TRANSIENT_PROVIDER_ID = 1;
    private const int64 TEST_AUTO_DOWNLOAD_MAX_BYTES = 5000000;
    private const string ESFS_GCM_CIPHER = "urn:xmpp:ciphers:aes-256-gcm-nopadding:0";
    private const string ESFS_CBC_CIPHER = "urn:xmpp:ciphers:aes-256-cbc-pkcs7:0";
    private const string ESFS_SUBSTRING_GCM_CIPHER = "urn:xmpp:ciphers:not-aes-256-gcm:0";
    private const string ESFS_SUBSTRING_CBC_CIPHER = "urn:xmpp:ciphers:aes-256-cbc-unpadded:0";

    // Helper: create FileTransfer, set file_name, return sanitized value
    private string sanitize(string input) {
        var ft = new Dino.Entities.FileTransfer();
        ft.file_name = input;
        return ft.file_name;
    }

    // --- file_name sanitization ---

    private void test_path_traversal() {
        // ../../etc/passwd should be stripped to "passwd"
        string result = sanitize("../../etc/passwd");
        fail_if_not_eq_str(result, "passwd",
            "Path traversal should be stripped to basename");
    }

    private void test_absolute_path() {
        string result = sanitize("/etc/shadow");
        fail_if_not_eq_str(result, "shadow",
            "Absolute path should be stripped to basename");
    }

    private void test_hidden_file() {
        // .bashrc should get underscore prefix → "_.bashrc"
        string result = sanitize(".bashrc");
        fail_if_not_eq_str(result, "_.bashrc",
            "Hidden file should get underscore prefix");
    }

    private void test_dotdot_name() {
        // ".." as filename → Path.get_basename("..") = ".."
        // Then has_prefix(".") → "_" + ".." = "_.."
        string result = sanitize("..");
        fail_if(result == "..", "'..' should not be kept as-is");
    }

    private void test_separator_only() {
        // "/" as filename → Path.get_basename("/") = "/"
        // Then check: "/" == Path.DIR_SEPARATOR_S → "unknown filename"
        string result = sanitize("/");
        fail_if_not_eq_str(result, "unknown filename",
            "Separator-only should become 'unknown filename'");
    }

    private void test_dot_only() {
        // "." as filename → Path.get_basename(".") = "."
        // Then check: "." == "." → "unknown filename"
        string result = sanitize(".");
        fail_if_not_eq_str(result, "unknown filename",
            "Dot-only should become 'unknown filename'");
    }

    private void test_windows_path() {
        string result = sanitize("C:\\Users\\info\\Pictures\\photo.jpg");
        fail_if_not_eq_str(result, "photo.jpg",
            "Windows path components should be stripped to basename");
    }

    private void test_invalid_windows_chars() {
        string result = sanitize("bad:name?.jpg");
        fail_if_not_eq_str(result, "bad_name_.jpg",
            "Windows-invalid filename characters should be replaced");
    }

    private void test_control_chars() {
        string result = sanitize("photo.jpg\r");
        fail_if_not_eq_str(result, "photo.jpg",
            "Trailing control characters from status output should be removed");
    }

    private void test_image_filename_fallback() {
        fail_if_not(Dino.Util.can_preview_image("application/octet-stream", "photo.jpg"),
            "Image filenames should be previewable when server MIME is generic");
    }

    private void test_svg_filename_not_previewed() {
        fail_if(Dino.Util.can_preview_image("application/octet-stream", "diagram.svg"),
            "SVG filenames should stay disabled for preview");
    }

    private void test_normal_filename() {
        string result = sanitize("photo.jpg");
        fail_if_not_eq_str(result, "photo.jpg",
            "Normal filename should be preserved");
    }

    private void test_filename_spaces() {
        string result = sanitize("my photo.jpg");
        fail_if_not_eq_str(result, "my photo.jpg",
            "Filename with spaces should be preserved");
    }

    // --- transfer phase state/progress ---

    private void test_phase_active_resets_progress() {
        Dino.Entities.FileTransfer.Phase[] active_phases = {
            Dino.Entities.FileTransfer.Phase.PREPARING,
            Dino.Entities.FileTransfer.Phase.ENCRYPTING,
            Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
            Dino.Entities.FileTransfer.Phase.UPLOADING,
            Dino.Entities.FileTransfer.Phase.ANNOUNCING,
            Dino.Entities.FileTransfer.Phase.DOWNLOADING,
            Dino.Entities.FileTransfer.Phase.DECRYPTING,
            Dino.Entities.FileTransfer.Phase.VERIFYING,
            Dino.Entities.FileTransfer.Phase.STORING,
            Dino.Entities.FileTransfer.Phase.PREVIEWING
        };

        foreach (Dino.Entities.FileTransfer.Phase phase in active_phases) {
            var ft = new Dino.Entities.FileTransfer();
            ft.phase_total_bytes = 100;
            ft.transferred_bytes = 75;

            ft.set_transfer_phase(phase);

            fail_if_not(ft.state == Dino.Entities.FileTransfer.State.IN_PROGRESS,
                "Active phases must map to IN_PROGRESS");
            fail_if_not(ft.phase == phase,
                "Phase should be updated");
            fail_if_not(ft.phase_total_bytes == -1,
                "Active phase changes must clear stale phase totals");
            fail_if_not(ft.transferred_bytes == 0,
                "Active phase changes must clear stale progress");
        }
    }

    private void test_phase_notify_exposes_reset_progress() {
        var ft = new Dino.Entities.FileTransfer();
        ft.phase_total_bytes = 100;
        ft.transferred_bytes = 75;

        ft.notify["phase"].connect(() => {
            fail_if_not(ft.phase_total_bytes == -1,
                "Phase notifications must not expose stale phase totals");
            fail_if_not(ft.transferred_bytes == 0,
                "Phase notifications must not expose stale progress");
        });

        ft.set_transfer_phase(Dino.Entities.FileTransfer.Phase.DECRYPTING);
    }

    private void test_phase_complete_sets_terminal_progress() {
        var ft = new Dino.Entities.FileTransfer();
        ft.size = 42;
        ft.phase_error = "old error";
        ft.set_transfer_phase(Dino.Entities.FileTransfer.Phase.COMPLETE);

        fail_if_not(ft.state == Dino.Entities.FileTransfer.State.COMPLETE,
            "Complete phase must map to COMPLETE");
        fail_if_not(ft.phase_total_bytes == 42,
            "Complete phase should expose final size as phase total");
        fail_if_not(ft.transferred_bytes == 42,
            "Complete phase should expose final transferred bytes");
        fail_if(ft.phase_error != null,
            "Complete phase must clear old phase errors");
    }

    private void test_phase_none_resets_to_not_started() {
        var ft = new Dino.Entities.FileTransfer();
        ft.phase_total_bytes = 100;
        ft.transferred_bytes = 75;
        ft.set_transfer_phase(Dino.Entities.FileTransfer.Phase.NONE);

        fail_if_not(ft.state == Dino.Entities.FileTransfer.State.NOT_STARTED,
            "None phase must map to NOT_STARTED");
        fail_if_not(ft.phase_total_bytes == -1,
            "None phase should clear phase totals");
        fail_if_not(ft.transferred_bytes == 0,
            "None phase should clear transferred bytes");
    }

    private void test_phase_failed_keeps_error() {
        var ft = new Dino.Entities.FileTransfer();
        ft.set_transfer_phase(Dino.Entities.FileTransfer.Phase.FAILED, "hash verification failed");

        fail_if_not(ft.state == Dino.Entities.FileTransfer.State.FAILED,
            "Failed phase must map to FAILED");
        fail_if_not_eq_str(ft.phase_error, "hash verification failed",
            "Failed phase should keep the failure reason for UI text");
    }

    private void test_persistent_state_never_writes_in_progress() {
        fail_if(Dino.Entities.FileTransfer.persistent_state_for(Dino.Entities.FileTransfer.State.IN_PROGRESS) ==
                Dino.Entities.FileTransfer.State.IN_PROGRESS,
            "Runtime-only in-progress state must not be persisted");
        fail_if(Dino.Entities.FileTransfer.persistent_state_for(Dino.Entities.FileTransfer.State.FAILED) !=
                Dino.Entities.FileTransfer.State.FAILED,
            "Terminal failed state should persist unchanged");
        fail_if(Dino.Entities.FileTransfer.persistent_state_for(Dino.Entities.FileTransfer.State.COMPLETE) !=
                Dino.Entities.FileTransfer.State.COMPLETE,
            "Terminal complete state should persist unchanged");
        fail_if(Dino.Entities.FileTransfer.persistent_state_for(Dino.Entities.FileTransfer.State.NOT_STARTED) !=
                Dino.Entities.FileTransfer.State.NOT_STARTED,
            "Idle receive state should persist unchanged");
    }

    private void test_restart_recovery_marks_legacy_in_progress_failed() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-file-transfer-audit-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Dino.Database? db = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "file-transfer-restart-recovery-test");

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var counterpart = new Xmpp.Jid("bob@example.test");
            var conversation = new Dino.Entities.Conversation(counterpart, account, Dino.Entities.Conversation.Type.CHAT);

            int transfer_id = (int) ((!) db).file_transfer.insert()
                .value(((!) db).file_transfer.account_id, account.id)
                .value(((!) db).file_transfer.counterpart_id, ((!) db).get_jid_id(counterpart))
                .value(((!) db).file_transfer.direction, Dino.Entities.FileTransfer.DIRECTION_RECEIVED)
                .value(((!) db).file_transfer.time, (long) (new DateTime.now_utc()).to_unix())
                .value(((!) db).file_transfer.local_time, (long) (new DateTime.now_utc()).to_unix())
                .value(((!) db).file_transfer.encryption, Dino.Entities.Encryption.NONE)
                .value(((!) db).file_transfer.file_name, "stale-receive.bin")
                .value(((!) db).file_transfer.path, "stale-receive.bin")
                .value(((!) db).file_transfer.size, (long) 1024)
                .value(((!) db).file_transfer.state, (int) Dino.Entities.FileTransfer.State.IN_PROGRESS)
                .value(((!) db).file_transfer.provider, 1)
                .value(((!) db).file_transfer.info, "legacy-session")
                .perform();

            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);

            Qlite.RowOption row = ((!) db).file_transfer.select()
                .with(((!) db).file_transfer.id, "=", transfer_id)
                .single()
                .row();
            fail_if(!row.is_present(), "legacy transfer row must stay present after recovery");
            var persisted_state = (Dino.Entities.FileTransfer.State) ((!) row.inner)[((!) db).file_transfer.state];
            fail_if(persisted_state != Dino.Entities.FileTransfer.State.FAILED,
                "startup recovery must turn legacy in-progress rows into failed rows");

            Dino.FileTransferStorage? storage = stream_interactor.get_module<Dino.FileTransferStorage>(Dino.FileTransferStorage.IDENTITY);
            fail_if(storage == null, "test setup must start FileTransferStorage");
            Dino.Entities.FileTransfer? loaded = ((!) storage).get_file_by_id(transfer_id, conversation);
            fail_if(loaded == null, "recovered transfer must still be loadable");
            Dino.Entities.FileTransfer loaded_transfer = (!) loaded;
            fail_if(loaded_transfer.state != Dino.Entities.FileTransfer.State.FAILED,
                "loaded recovered transfer must expose FAILED state");
            fail_if(loaded_transfer.phase != Dino.Entities.FileTransfer.Phase.FAILED,
                "loaded recovered transfer must expose FAILED phase");
            fail_if(!loaded_transfer.can_start_receive_attempt(),
                "recovered received transfer must be retryable as a fresh receive attempt");
        } catch (Error e) {
            fail_if_reached(@"Restart recovery audit failed: $(e.message)");
        } finally {
            if (db != null) {
                ((!) db).close();
            }
            FileUtils.remove(db_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_database_removes_orphaned_content_items() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(), "dinox-content-item-audit-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Dino.Database? db = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "content-item-orphan-cleanup-test");

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var counterpart = new Xmpp.Jid("bob@example.test");
            var conversation = new Dino.Entities.Conversation(counterpart, account, Dino.Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);

            DateTime now = new DateTime.now_utc();
            int orphan_message_item_id = ((!) db).add_content_item(conversation, now, now, 1, 99, false);
            int orphan_file_item_id = ((!) db).add_content_item(conversation, now, now, 2, 15, false);
            int orphan_call_item_id = ((!) db).add_content_item(conversation, now, now, 3, 77, false);
            int invalid_type_item_id = ((!) db).add_content_item(conversation, now, now, 99, 1, false);
            int valid_transfer_id = (int) ((!) db).file_transfer.insert()
                .value(((!) db).file_transfer.account_id, account.id)
                .value(((!) db).file_transfer.counterpart_id, ((!) db).get_jid_id(counterpart))
                .value(((!) db).file_transfer.direction, Dino.Entities.FileTransfer.DIRECTION_RECEIVED)
                .value(((!) db).file_transfer.time, (long) now.to_unix())
                .value(((!) db).file_transfer.local_time, (long) now.to_unix())
                .value(((!) db).file_transfer.encryption, Dino.Entities.Encryption.NONE)
                .value(((!) db).file_transfer.file_name, "valid.bin")
                .value(((!) db).file_transfer.path, "valid.bin")
                .value(((!) db).file_transfer.size, (long) 42)
                .value(((!) db).file_transfer.state, (int) Dino.Entities.FileTransfer.State.NOT_STARTED)
                .value(((!) db).file_transfer.provider, 1)
                .value(((!) db).file_transfer.info, "valid-session")
                .perform();
            int valid_item_id = ((!) db).add_content_item(conversation, now, now, 2, valid_transfer_id, false);
            ((!) db).conversation.update()
                .with(((!) db).conversation.id, "=", conversation.id)
                .set(((!) db).conversation.read_up_to_item, orphan_file_item_id)
                .perform();

            ((!) db).cleanup_orphaned_content_items();

            assert_content_item_missing((!) db, orphan_message_item_id,
                "Database cleanup must remove message content items whose message row is missing");
            assert_content_item_missing((!) db, orphan_file_item_id,
                "Database cleanup must remove file content items whose file_transfer row is missing");
            assert_content_item_missing((!) db, orphan_call_item_id,
                "Database cleanup must remove call content items whose call row is missing");
            assert_content_item_missing((!) db, invalid_type_item_id,
                "Database cleanup must remove content items with invalid content types");

            Qlite.RowOption valid_item = ((!) db).content_item.select()
                .with(((!) db).content_item.id, "=", valid_item_id)
                .single()
                .row();
            fail_if(!valid_item.is_present(),
                "Database cleanup must keep file content items with an existing file_transfer row");

            Qlite.RowOption conversation_row = ((!) db).conversation.select()
                .with(((!) db).conversation.id, "=", conversation.id)
                .single()
                .row();
            fail_if(!conversation_row.is_present(), "conversation row must stay present");
            int read_up_to_item = ((!) conversation_row.inner)[((!) db).conversation.read_up_to_item];
            fail_if(read_up_to_item != -1,
                "Database cleanup must clear read_up_to_item when it pointed to an orphaned content item");
        } catch (Error e) {
            fail_if_reached(@"Content item orphan cleanup audit failed: $(e.message)");
        } finally {
            if (db != null) {
                ((!) db).close();
            }
            FileUtils.remove(db_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void assert_content_item_missing(Dino.Database db, int content_item_id, string reason) {
        Qlite.RowOption row = db.content_item.select()
            .with(db.content_item.id, "=", content_item_id)
            .single()
            .row();
        fail_if(row.is_present(), reason);
    }

    private void test_transfer_attempt_replaces_cancelled_cancellable() {
        var ft = new Dino.Entities.FileTransfer();
        Cancellable old_cancellable = ft.cancellable;
        old_cancellable.cancel();

        ft.prepare_transfer_attempt();

        fail_if(old_cancellable == ft.cancellable,
            "A new transfer attempt must not reuse a cancelled cancellable");
        fail_if(ft.cancellable.is_cancelled(),
            "A new transfer attempt must start with a live cancellable");
    }

    private void test_plaintext_release_requires_complete_transfer() {
        Dino.Entities.FileTransfer.State[] blocked_states = {
            Dino.Entities.FileTransfer.State.NOT_STARTED,
            Dino.Entities.FileTransfer.State.IN_PROGRESS,
            Dino.Entities.FileTransfer.State.FAILED
        };

        foreach (Dino.Entities.FileTransfer.State blocked_state in blocked_states) {
            var ft = new Dino.Entities.FileTransfer();
            ft.state = blocked_state;
            fail_if(ft.is_plaintext_release_allowed(),
                "Plaintext release must stay blocked until the transfer is complete");
        }

        Dino.Entities.FileTransfer.Phase[] active_phases = {
            Dino.Entities.FileTransfer.Phase.PREPARING,
            Dino.Entities.FileTransfer.Phase.ENCRYPTING,
            Dino.Entities.FileTransfer.Phase.REQUESTING_SLOT,
            Dino.Entities.FileTransfer.Phase.UPLOADING,
            Dino.Entities.FileTransfer.Phase.ANNOUNCING,
            Dino.Entities.FileTransfer.Phase.DOWNLOADING,
            Dino.Entities.FileTransfer.Phase.DECRYPTING,
            Dino.Entities.FileTransfer.Phase.VERIFYING,
            Dino.Entities.FileTransfer.Phase.STORING,
            Dino.Entities.FileTransfer.Phase.PREVIEWING
        };

        foreach (Dino.Entities.FileTransfer.Phase active_phase in active_phases) {
            var ft = new Dino.Entities.FileTransfer();
            ft.set_transfer_phase(active_phase);
            fail_if(ft.is_plaintext_release_allowed(),
                "Plaintext release must stay blocked for every active transfer phase");
        }

        var complete = new Dino.Entities.FileTransfer();
        complete.state = Dino.Entities.FileTransfer.State.COMPLETE;
        fail_if(!complete.is_plaintext_release_allowed(),
            "Complete transfers should be available for preview/open/save");
    }

    private void test_prepared_meta_updates_safe_transfer_fields() {
        var ft = new Dino.Entities.FileTransfer();
        ft.file_name = "photo.jpg#secret";
        ft.mime_type = "application/octet-stream";
        ft.size = 117;
        ft.state = Dino.Entities.FileTransfer.State.IN_PROGRESS;

        var prepared_meta = new Dino.FileMeta();
        prepared_meta.file_name = "photo.jpg";
        prepared_meta.mime_type = "image/jpeg";
        prepared_meta.size = 101;

        prepared_meta.apply_safe_fields_to_transfer(ft);

        fail_if_not_eq_str(ft.file_name, "photo.jpg",
            "Prepared decryptor metadata should replace fragment-bearing transport names");
        fail_if_not_eq_str(ft.mime_type, "image/jpeg",
            "Prepared decryptor metadata should restore the plaintext MIME type");
        fail_if(ft.size != 117,
            "Prepared decryptor metadata must not replace the transport size before download");
        fail_if(ft.state != Dino.Entities.FileTransfer.State.IN_PROGRESS,
            "Prepared metadata must not release plaintext by completing the transfer");
        fail_if(ft.is_plaintext_release_allowed(),
            "Prepared metadata must keep plaintext release blocked before completion");

        ft.set_transfer_phase(Dino.Entities.FileTransfer.Phase.COMPLETE);
        fail_if(ft.phase_total_bytes != 117 || ft.transferred_bytes != 117,
            "Terminal progress should keep using the existing transfer size");
    }

    private void test_prepared_meta_ignores_missing_fields() {
        var ft = new Dino.Entities.FileTransfer();
        ft.file_name = "document.pdf";
        ft.mime_type = "application/pdf";
        ft.size = 4096;

        var prepared_meta = new Dino.FileMeta();
        prepared_meta.file_name = "";
        prepared_meta.mime_type = " ";
        prepared_meta.size = -1;

        prepared_meta.apply_safe_fields_to_transfer(ft);

        fail_if_not_eq_str(ft.file_name, "document.pdf",
            "Missing prepared filenames must not clobber the existing transfer name");
        fail_if_not_eq_str(ft.mime_type, "application/pdf",
            "Missing prepared MIME types must not clobber the existing transfer MIME type");
        fail_if(ft.size != 4096,
            "Missing prepared sizes must not clobber the existing transfer size");
    }

    private void test_provider_meta_updates_transport_size() {
        var ft = new Dino.Entities.FileTransfer();
        ft.file_name = "download.bin";
        ft.mime_type = "application/octet-stream";
        ft.size = 117;

        var provider_meta = new Dino.FileMeta();
        provider_meta.file_name = "archive.zip";
        provider_meta.mime_type = "application/zip";
        provider_meta.size = 2048;

        provider_meta.apply_transport_fields_to_transfer(ft);

        fail_if_not_eq_str(ft.file_name, "archive.zip",
            "Provider metadata should update the transport filename");
        fail_if_not_eq_str(ft.mime_type, "application/zip",
            "Provider metadata should update the transport MIME type");
        fail_if(ft.size != 2048,
            "Provider metadata should keep updating the transport size");
    }

    private void test_receive_encryption_classification_provider_wins() {
        Dino.Entities.Encryption resolved = Dino.Entities.FileTransfer.resolve_received_encryption(
            Dino.Entities.Encryption.PGP,
            Dino.Entities.Encryption.OMEMO
        );

        fail_if(resolved != Dino.Entities.Encryption.PGP,
            "Provider-level message encryption must win over decryptor fallback classification");
    }

    private void test_receive_encryption_classification_uses_decryptor_fallback() {
        Dino.Entities.Encryption resolved = Dino.Entities.FileTransfer.resolve_received_encryption(
            Dino.Entities.Encryption.NONE,
            Dino.Entities.Encryption.OMEMO
        );

        fail_if(resolved != Dino.Entities.Encryption.OMEMO,
            "Decryptor classification should apply only when the provider did not classify encryption");
    }

    private void test_receive_store_phase_matches_pipeline_kind() {
        fail_if(Dino.Entities.FileTransfer.receive_store_phase_for(false, false) != Dino.Entities.FileTransfer.Phase.DOWNLOADING,
            "Plain receive streams should keep the user-facing download phase while writing to local storage");
        fail_if(Dino.Entities.FileTransfer.receive_store_phase_for(true, false) != Dino.Entities.FileTransfer.Phase.DECRYPTING,
            "Streaming decryptors should keep the user-facing decrypt phase while storing plaintext");
        fail_if(Dino.Entities.FileTransfer.receive_store_phase_for(true, true) != Dino.Entities.FileTransfer.Phase.STORING,
            "Decrypt-before-return paths should switch to storing after decryption completed");
    }

    private void test_receive_attempt_only_starts_from_idle_or_failed() {
        var idle = new Dino.Entities.FileTransfer();
        idle.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
        idle.state = Dino.Entities.FileTransfer.State.NOT_STARTED;
        fail_if(!idle.can_start_receive_attempt(),
            "A not-started receive transfer should be downloadable");

        var failed = new Dino.Entities.FileTransfer();
        failed.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
        failed.state = Dino.Entities.FileTransfer.State.FAILED;
        fail_if(!failed.can_start_receive_attempt(),
            "A failed receive transfer should remain retryable");

        var active = new Dino.Entities.FileTransfer();
        active.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
        active.state = Dino.Entities.FileTransfer.State.IN_PROGRESS;
        fail_if(active.can_start_receive_attempt(),
            "An active receive transfer must not start a second concurrent attempt");

        var complete = new Dino.Entities.FileTransfer();
        complete.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
        complete.state = Dino.Entities.FileTransfer.State.COMPLETE;
        fail_if(complete.can_start_receive_attempt(),
            "A completed receive transfer must not be downloaded again");

        var failed_send = new Dino.Entities.FileTransfer();
        failed_send.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        failed_send.state = Dino.Entities.FileTransfer.State.FAILED;
        fail_if(failed_send.can_start_receive_attempt(),
            "A failed send transfer must not be treated as a receive download retry");
    }

    private void test_send_retry_requires_failed_sent_local_copy() {
        var retryable = new Dino.Entities.FileTransfer();
        retryable.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        retryable.state = Dino.Entities.FileTransfer.State.FAILED;
        retryable.path = "local-copy.bin";
        fail_if(!retryable.can_retry_send_attempt(),
            "A failed sent transfer with a local copy should be retryable");

        var missing_copy = new Dino.Entities.FileTransfer();
        missing_copy.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        missing_copy.state = Dino.Entities.FileTransfer.State.FAILED;
        fail_if(missing_copy.can_retry_send_attempt(),
            "A failed sent transfer without a local copy must not be retryable");

        var empty_path = new Dino.Entities.FileTransfer();
        empty_path.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        empty_path.state = Dino.Entities.FileTransfer.State.FAILED;
        empty_path.path = "";
        fail_if(empty_path.can_retry_send_attempt(),
            "A failed sent transfer with an empty local path must not be retryable");

        var received = new Dino.Entities.FileTransfer();
        received.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
        received.state = Dino.Entities.FileTransfer.State.FAILED;
        received.path = "local-copy.bin";
        fail_if(received.can_retry_send_attempt(),
            "A failed received transfer must not enter the send retry path");

        var complete = new Dino.Entities.FileTransfer();
        complete.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        complete.state = Dino.Entities.FileTransfer.State.COMPLETE;
        complete.path = "local-copy.bin";
        fail_if(complete.can_retry_send_attempt(),
            "A completed sent transfer must not start another upload");

        var active = new Dino.Entities.FileTransfer();
        active.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        active.state = Dino.Entities.FileTransfer.State.IN_PROGRESS;
        active.path = "local-copy.bin";
        fail_if(active.can_retry_send_attempt(),
            "An active sent transfer must not start a second concurrent upload");
    }

    private void test_sfs_download_source_missing_until_source_arrives() {
        var ft = make_sfs_transfer(Dino.Entities.Encryption.NONE);

        fail_if(ft.has_usable_download_source(TEST_SFS_PROVIDER_ID),
            "Incoming SFS transfers without sources should not be downloadable yet");
    }

    private void test_message_relation_prefers_explicit_id_and_keeps_legacy_fallback() {
        var transfer = new Dino.Entities.FileTransfer();
        transfer.info = "41";
        fail_if(transfer.resolve_message_db_id() != 41,
            "numeric legacy transport info must remain readable after the schema migration");

        transfer.message_db_id = 73;
        transfer.info = "url:https://upload.example.test/file.bin";
        fail_if(transfer.resolve_message_db_id() != 73,
            "the explicit message relation must be independent from a transport URL");

        transfer.message_db_id = -1;
        fail_if(transfer.resolve_message_db_id() != -1,
            "transport URLs must never be mistaken for local message ids");

        transfer.provider = TEST_TRANSIENT_PROVIDER_ID;
        transfer.info = "41";
        fail_if(transfer.resolve_message_db_id() != -1,
            "numeric Jingle session identifiers must never be mistaken for local message ids");
    }

    private void test_database_v50_migration_backfills_only_canonical_message_relations() {
        string temp_dir = "";
        string db_path = "";
        const string db_key = "file-relation-v50-test";
        Dino.Database? db = null;
        Sqlite.Database? raw_db = null;

        try {
            // Other audit cases seed GLib.Random. UUID-derived names could
            // reopen a stale fixture left by a fatal previous migration test.
            temp_dir = DirUtils.make_tmp("dinox-file-relation-v50-XXXXXX");
            db_path = Path.build_filename(temp_dir, "dino.db");
            db = new Dino.Database(db_path, db_key);

            var account = new Dino.Entities.Account(
                new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var counterpart = new Xmpp.Jid("bob@example.test");
            var conversation = new Dino.Entities.Conversation(counterpart,
                account, Dino.Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);
            DateTime base_time = new DateTime.from_unix_utc(1700000000);

            Xmpp.Jid own_desktop = account.bare_jid.with_resource("desktop");
            var message = persist_v50_relation_fixture_message((!) db,
                account, counterpart, own_desktop,
                Dino.Entities.Message.DIRECTION_SENT,
                Dino.Entities.Message.Type.CHAT, "legacy file message",
                base_time);

            var canonical = persist_v50_relation_fixture_transfer((!) db,
                conversation, account, counterpart, own_desktop,
                message.id.to_string(),
                Dino.Entities.FileTransfer.DIRECTION_SENT,
                TEST_SFS_PROVIDER_ID, base_time);
            var jingle = persist_v50_relation_fixture_transfer((!) db,
                conversation, account, counterpart, own_desktop,
                message.id.to_string(),
                Dino.Entities.FileTransfer.DIRECTION_SENT,
                TEST_TRANSIENT_PROVIDER_ID, base_time);
            var numeric_prefix = persist_v50_relation_fixture_transfer((!) db,
                conversation, account, counterpart, own_desktop,
                message.id.to_string() + "-jingle",
                Dino.Entities.FileTransfer.DIRECTION_SENT,
                TEST_SFS_PROVIDER_ID, base_time.add_seconds(1));
            var wrong_direction = persist_v50_relation_fixture_transfer((!) db,
                conversation, account, counterpart, own_desktop,
                message.id.to_string(),
                Dino.Entities.FileTransfer.DIRECTION_RECEIVED,
                TEST_SFS_PROVIDER_ID, base_time.add_seconds(2));
            var missing_message = persist_v50_relation_fixture_transfer((!) db,
                conversation, account, counterpart, own_desktop,
                "2147483647",
                Dino.Entities.FileTransfer.DIRECTION_SENT,
                TEST_SFS_PROVIDER_ID, base_time.add_seconds(3));

            string unique_url =
                "https://upload.example.test/private-muc-file.bin";
            DateTime unique_url_time = base_time.add_seconds(10);
            Xmpp.Jid private_peer = new Xmpp.Jid(
                "room@conference.example.test/Mallory");
            Xmpp.Jid own_occupant = new Xmpp.Jid(
                "room@conference.example.test/Alice");
            var private_conversation = new Dino.Entities.Conversation(
                private_peer, account,
                Dino.Entities.Conversation.Type.GROUPCHAT_PM);
            private_conversation.muc_pm_peer_identity =
                "jid:mallory@example.test";
            private_conversation.persist((!) db);
            var unique_url_message = persist_v50_relation_fixture_message(
                (!) db, account, private_peer, own_occupant,
                Dino.Entities.Message.DIRECTION_RECEIVED,
                Dino.Entities.Message.Type.GROUPCHAT_PM, unique_url,
                unique_url_time);
            var unique_url_transfer = persist_v50_relation_fixture_transfer(
                (!) db, private_conversation, account, private_peer,
                own_occupant, "url:" + unique_url,
                Dino.Entities.FileTransfer.DIRECTION_RECEIVED,
                0, unique_url_time);

            // Legacy private-MUC sends used the room nick on the transfer,
            // although their type='chat' message used the account resource.
            // Both relation formats must migrate and normalise that mismatch.
            Xmpp.Jid own_account_resource = account.bare_jid.with_resource(
                "desktop");
            DateTime sent_numeric_time = base_time.add_seconds(11);
            var sent_numeric_message = persist_v50_relation_fixture_message(
                (!) db, account, private_peer, own_account_resource,
                Dino.Entities.Message.DIRECTION_SENT,
                Dino.Entities.Message.Type.GROUPCHAT_PM,
                "private MUC numeric file", sent_numeric_time);
            var sent_numeric_transfer = persist_v50_relation_fixture_transfer(
                (!) db, private_conversation, account, private_peer,
                own_occupant, sent_numeric_message.id.to_string(),
                Dino.Entities.FileTransfer.DIRECTION_SENT,
                TEST_SFS_PROVIDER_ID, sent_numeric_time);

            string sent_url =
                "https://upload.example.test/private-muc-sent.bin";
            DateTime sent_url_time = base_time.add_seconds(12);
            var sent_url_message = persist_v50_relation_fixture_message(
                (!) db, account, private_peer, own_account_resource,
                Dino.Entities.Message.DIRECTION_SENT,
                Dino.Entities.Message.Type.GROUPCHAT_PM, sent_url,
                sent_url_time);
            var sent_url_transfer = persist_v50_relation_fixture_transfer(
                (!) db, private_conversation, account, private_peer,
                own_occupant, "url:" + sent_url,
                Dino.Entities.FileTransfer.DIRECTION_SENT, 0,
                sent_url_time);

            // Same URL and timestamp, but neither the wrong occupant nor the
            // wrong message type belongs to this private-MUC content item.
            persist_v50_relation_fixture_message((!) db, account,
                new Xmpp.Jid("room@conference.example.test/Eve"),
                own_occupant, Dino.Entities.Message.DIRECTION_RECEIVED,
                Dino.Entities.Message.Type.GROUPCHAT_PM, unique_url,
                unique_url_time);
            persist_v50_relation_fixture_message((!) db, account,
                private_peer, own_occupant,
                Dino.Entities.Message.DIRECTION_RECEIVED,
                Dino.Entities.Message.Type.CHAT, unique_url,
                unique_url_time);

            string ambiguous_url =
                "https://upload.example.test/ambiguous.bin";
            DateTime ambiguous_time = base_time.add_seconds(20);
            persist_v50_relation_fixture_message((!) db, account,
                counterpart, own_desktop,
                Dino.Entities.Message.DIRECTION_RECEIVED,
                Dino.Entities.Message.Type.CHAT, ambiguous_url,
                ambiguous_time);
            persist_v50_relation_fixture_message((!) db, account,
                counterpart, own_desktop,
                Dino.Entities.Message.DIRECTION_RECEIVED,
                Dino.Entities.Message.Type.CHAT, ambiguous_url,
                ambiguous_time);
            var ambiguous_url_transfer =
                persist_v50_relation_fixture_transfer((!) db, conversation,
                    account, counterpart, own_desktop,
                    "url:" + ambiguous_url,
                    Dino.Entities.FileTransfer.DIRECTION_RECEIVED,
                    0, ambiguous_time);

            string body_mismatch_url =
                "https://upload.example.test/oob-only.bin";
            DateTime body_mismatch_time = base_time.add_seconds(30);
            persist_v50_relation_fixture_message((!) db, account,
                counterpart, own_desktop,
                Dino.Entities.Message.DIRECTION_RECEIVED,
                Dino.Entities.Message.Type.CHAT,
                "Download the attached file", body_mismatch_time);
            var body_mismatch_transfer =
                persist_v50_relation_fixture_transfer((!) db, conversation,
                    account, counterpart, own_desktop,
                    "url:" + body_mismatch_url,
                    Dino.Entities.FileTransfer.DIRECTION_RECEIVED,
                    0, body_mismatch_time);

            // Build the real historical conversation definition before
            // downgrading metadata; later columns must not pre-exist during
            // the migration. This preserves keys/defaults without relying
            // on DROP COLUMN support.
            ((!) db).exec("ALTER TABLE conversation RENAME TO conversation_post56_fixture");
            ((!) db).conversation.create_table_at_version(50);
            rebuild_account_fixture_at_version((!) db, 50);
            ((!) db).exec("""
INSERT INTO conversation (
    id, account_id, jid_id, resource, active, active_last_changed,
    last_active, type, encryption, read_up_to, read_up_to_item,
    notification, send_typing, send_marker, pinned, history_cleared_at,
    message_expiry_seconds, muc_pm_peer_identity)
SELECT id, account_id, jid_id, resource, active, active_last_changed,
    last_active, type, encryption, read_up_to, read_up_to_item,
    notification, send_typing, send_marker, pinned, history_cleared_at,
    message_expiry_seconds, muc_pm_peer_identity
FROM conversation_post56_fixture;
DROP TABLE conversation_post56_fixture;
""");
            ((!) db).close();
            db = null;

            int open_result = Sqlite.Database.open_v2(db_path, out raw_db,
                Sqlite.OPEN_READWRITE | 0x00010000);
            if (open_result != Sqlite.OK) {
                throw new IOError.FAILED(
                    "could not open the generated database as a v50 fixture");
            }
            sqlite_exec_or_throw((!) raw_db,
                "PRAGMA key = 'file-relation-v50-test'");
            // Rebuild the fixture table instead of using DROP COLUMN, which is
            // unavailable in older SQLite/SQLCipher versions still supported
            // by DinoX.
            sqlite_exec_or_throw((!) raw_db, """
                CREATE TABLE file_transfer_v50_fixture AS SELECT
                    id, file_sharing_id, account_id, counterpart_id,
                    counterpart_resource, our_resource, direction, time,
                    local_time, encryption, file_name, path, mime_type, size,
                    state, encryption_protocol, provider, info,
                    modification_date, width, height, length, retry_count,
                    next_retry_time, last_attempt_time, is_sticker,
                    sticker_pack_id, sticker_pack_jid, sticker_pack_node
                FROM file_transfer;
                DROP TABLE file_transfer;
                ALTER TABLE file_transfer_v50_fixture RENAME TO file_transfer;
            """);
            // This downgrade must also remove later message columns; real
            // v50 profiles do not already contain the v54 diagnostic flags.
            sqlite_exec_or_throw((!) raw_db, """
CREATE TABLE message_pre54_fixture AS SELECT
    id, stanza_id, server_id, sender_stanza_id, stable_id, stable_id_by,
    account_id, counterpart_id, counterpart_resource, our_resource,
    direction, type, time, local_time, body, encryption, encryption_protocol,
    marked, markable FROM message;
DROP TABLE message;
ALTER TABLE message_pre54_fixture RENAME TO message;
""");
            sqlite_exec_or_throw((!) raw_db,
                "UPDATE _meta SET int_val = 50 WHERE name = 'version'");
            fail_if(sqlite_query_single_int((!) raw_db,
                    "SELECT COUNT(*) FROM pragma_table_info('message') " +
                    "WHERE name IN ('decryption_failed', 'encryption_time_mismatch')") != 0,
                "the migration fixture must also have the real pre-v54 message schema");
            fail_if(sqlite_query_single_int((!) raw_db,
                    "SELECT COUNT(*) FROM pragma_table_info('file_transfer') " +
                    "WHERE name = 'message_id'") != 0,
                "the migration fixture must have the real v50 file_transfer schema");
            raw_db = null;

            db = new Dino.Database(db_path, db_key);
            fail_if(migrated_message_relation((!) db, canonical.id) !=
                    message.id,
                "v50 canonical numeric info must be backfilled to message_id");
            fail_if(migrated_message_relation((!) db,
                    unique_url_transfer.id) != unique_url_message.id,
                "an exact, unique v50 HTTP URL relation in a private MUC must be backfilled");
            fail_if(migrated_message_relation((!) db,
                    sent_numeric_transfer.id) != sent_numeric_message.id,
                "a canonical outgoing private-MUC numeric relation must survive the legacy sender mismatch");
            fail_if(migrated_message_relation((!) db,
                    sent_url_transfer.id) != sent_url_message.id,
                "an exact outgoing private-MUC URL relation must survive the legacy sender mismatch");
            fail_if(migrated_our_resource((!) db,
                    sent_numeric_transfer.id) != "desktop" ||
                    migrated_our_resource((!) db,
                        sent_url_transfer.id) != "desktop",
                "migrated outgoing private-MUC transfers must use the account resource of their backing message");
            fail_if(migrated_message_relation((!) db,
                    ambiguous_url_transfer.id) != -1,
                "multiple exact HTTP message candidates must remain fail-closed");
            fail_if(migrated_message_relation((!) db,
                    body_mismatch_transfer.id) != -1,
                "an OOB URL without an exact message-body proof must remain unrelated");
            fail_if(migrated_message_relation((!) db, jingle.id) != -1,
                "a numeric Jingle session identifier must not be guessed as a message relation");
            fail_if(migrated_message_relation((!) db, numeric_prefix.id) != -1,
                "numeric prefixes in transport identifiers must not be accepted as message ids");
            fail_if(migrated_message_relation((!) db, wrong_direction.id) != -1,
                "a numeric value without a matching message direction must stay unrelated");
            fail_if(migrated_message_relation((!) db, missing_message.id) != -1,
                "a numeric value without an existing message must stay unrelated");
        } catch (Error e) {
            fail_if_reached(@"v50 file relation migration test failed: $(e.message)");
        } finally {
            raw_db = null;
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
            DirUtils.remove(temp_dir);
        }
    }

    private static Dino.Entities.FileTransfer
            persist_v50_relation_fixture_transfer(Dino.Database db,
                    Dino.Entities.Conversation conversation,
                    Dino.Entities.Account account, Xmpp.Jid counterpart,
                    Xmpp.Jid ourpart, string info, bool direction,
                    int provider, DateTime time) {
        var transfer = new Dino.Entities.FileTransfer();
        transfer.account = account;
        transfer.counterpart = counterpart;
        transfer.ourpart = ourpart;
        transfer.direction = direction;
        transfer.time = time;
        transfer.local_time = time;
        transfer.file_name = "fixture-" + time.to_unix().to_string() + ".bin";
        transfer.size = 1;
        transfer.provider = provider;
        transfer.info = info;
        transfer.persist(db);
        db.add_content_item(conversation, time, time, 2, transfer.id, false);
        return transfer;
    }

    private static Dino.Entities.Message
            persist_v50_relation_fixture_message(Dino.Database db,
                    Dino.Entities.Account account, Xmpp.Jid counterpart,
                    Xmpp.Jid ourpart, bool direction,
                    Dino.Entities.Message.Type type, string body,
                    DateTime time) {
        var message = new Dino.Entities.Message(body);
        message.account = account;
        message.counterpart = counterpart;
        message.ourpart = ourpart;
        message.direction = direction;
        message.type_ = type;
        message.time = time;
        message.local_time = time;
        message.body = body;
        message.stanza_id = Uuid.string_random();
        message.persist(db);
        return message;
    }

    private static int migrated_message_relation(Dino.Database db,
            int transfer_id) throws Error {
        Qlite.RowOption row = db.file_transfer.select()
            .with(db.file_transfer.id, "=", transfer_id)
            .single().row();
        if (!row.is_present()) {
            throw new IOError.FAILED(
                "migrated file transfer row is missing");
        }
        return ((!) row.inner)[db.file_transfer.message_id];
    }

    private static string? migrated_our_resource(Dino.Database db,
            int transfer_id) throws Error {
        Qlite.RowOption row = db.file_transfer.select()
            .with(db.file_transfer.id, "=", transfer_id)
            .single().row();
        if (!row.is_present()) {
            throw new IOError.FAILED(
                "migrated file transfer row is missing");
        }
        return ((!) row.inner)[db.file_transfer.our_resource];
    }

    private static void sqlite_exec_or_throw(Sqlite.Database db,
            string sql) throws Error {
        if (db.exec(sql, null, null) != Sqlite.OK) {
            throw new IOError.FAILED(
                "v50 fixture SQL failed: %s".printf(db.errmsg()));
        }
    }

    private static int sqlite_query_single_int(Sqlite.Database db,
            string sql) throws Error {
        Sqlite.Statement statement;
        if (db.prepare_v2(sql, -1, out statement) != Sqlite.OK ||
                statement.step() != Sqlite.ROW) {
            throw new IOError.FAILED(
                "v50 fixture query failed: %s".printf(db.errmsg()));
        }
        return statement.column_int(0);
    }

    private void test_live_message_relation_updates_storage_cache() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-file-message-cache-" + Uuid.string_random());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Dino.Database? db = null;
        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "file-message-cache-test");
            var account = new Dino.Entities.Account(
                new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var counterpart = new Xmpp.Jid("bob@example.test");
            var conversation = new Dino.Entities.Conversation(counterpart,
                account, Dino.Entities.Conversation.Type.CHAT);
            conversation.persist((!) db);
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);
            Dino.FileTransferStorage? storage = stream_interactor.get_module<Dino.FileTransferStorage>(
                Dino.FileTransferStorage.IDENTITY);
            fail_if(storage == null,
                "test setup must start FileTransferStorage");

            DateTime now = new DateTime.now_utc();
            var transfer = new Dino.Entities.FileTransfer();
            transfer.account = account;
            transfer.counterpart = counterpart;
            transfer.ourpart = account.bare_jid.with_resource("desktop");
            transfer.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
            transfer.time = now;
            transfer.local_time = now;
            transfer.file_name = "photo.jpg";
            transfer.size = 42;
            transfer.info = "pending-http-upload";
            ((!) storage).add_file(transfer);

            transfer.message_db_id = 73;
            transfer.info = "url:https://upload.example.test/photo.jpg";
            Dino.Entities.FileTransfer? loaded = ((!) storage).get_file_by_message_id(
                73, conversation);
            fail_if(loaded != transfer,
                "late message linkage must update the live storage cache without creating a second transfer object");

            Qlite.RowOption row = ((!) db).file_transfer.select()
                .with(((!) db).file_transfer.id, "=", transfer.id)
                .single().row();
            fail_if(!row.is_present() ||
                    ((!) row.inner)[((!) db).file_transfer.message_id] != 73,
                "late message linkage must be persisted independently from transport info");

            // Simulate a transfer restored after restart and then announced
            // again under a new message id by a manual or scheduled retry.
            var persisted_transfer = new Dino.Entities.FileTransfer();
            persisted_transfer.account = account;
            persisted_transfer.counterpart = counterpart;
            persisted_transfer.ourpart = account.bare_jid.with_resource(
                "desktop");
            persisted_transfer.direction =
                Dino.Entities.FileTransfer.DIRECTION_SENT;
            persisted_transfer.time = now.add_seconds(1);
            persisted_transfer.local_time = now.add_seconds(1);
            persisted_transfer.file_name = "retry.jpg";
            persisted_transfer.size = 84;
            persisted_transfer.message_db_id = 81;
            persisted_transfer.info = "81";
            persisted_transfer.persist((!) db);

            Dino.Entities.FileTransfer? restored = ((!) storage).get_file_by_id(
                persisted_transfer.id, conversation);
            fail_if(restored == null,
                "a persisted transfer must be materialized for retry");
            ((!) restored).message_db_id = 82;

            fail_if(((!) storage).get_file_by_message_id(81, conversation) != null,
                "an explicit retry relation must override a stale numeric transport-info fallback");

            ((!) restored).info =
                "url:https://upload.example.test/retry.jpg";

            ((!) db).file_transfer.delete()
                .with(((!) db).file_transfer.id, "=", persisted_transfer.id)
                .perform();
            Dino.Entities.FileTransfer? restored_from_live_cache =
                ((!) storage).get_file_by_message_id(82, conversation);
            fail_if(restored_from_live_cache != restored,
                "a restored transfer must observe late retry linkage without creating a second object");
        } catch (Error e) {
            fail_if_reached(@"Live file message cache test failed: $(e.message)");
        } finally {
            if (db != null) ((!) db).close();
            FileUtils.remove(db_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_sfs_pending_sources_replayed_when_share_arrives() {
        string temp_dir = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-sfs-pending-audit-" + Uuid.string_random() + "-" + GLib.get_monotonic_time().to_string());
        string db_path = Path.build_filename(temp_dir, "dino.db");
        Dino.Database? db = null;
        SfsPendingTestApplication? application = null;
        GLib.Application? previous_application = GLib.Application.get_default();

        try {
            DirUtils.create_with_parents(temp_dir, 0700);
            db = new Dino.Database(db_path, "sfs-pending-source-test");
            var stream_interactor = new Dino.StreamInteractor.for_tests((!) db);
            application = new SfsPendingTestApplication((!) db, stream_interactor);
            GLib.Application.set_default((!) application);

            Dino.MessageStorage.start(stream_interactor, (!) db);
            Dino.FileTransferStorage.start(stream_interactor, (!) db);
            Dino.MessageProcessor.start(stream_interactor, (!) db);
            Dino.RosterManager.start(stream_interactor, (!) db);
            Dino.FileManager.start(stream_interactor, (!) db, ((!) application).file_encryption);
            Dino.StatelessFileSharing.start(stream_interactor, (!) db);

            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.persist((!) db);
            var counterpart = new Xmpp.Jid("bob@example.test");
            var conversation = new Dino.Entities.Conversation(counterpart, account, Dino.Entities.Conversation.Type.CHAT);

            var sfs = stream_interactor.get_module<Dino.StatelessFileSharing>(Dino.StatelessFileSharing.IDENTITY);
            fail_if(sfs == null, "test setup must start StatelessFileSharing");

            var pending_sources = new Gee.ArrayList<Xmpp.Xep.StatelessFileSharing.Source>();
            pending_sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url = "https://example.test/plain.bin" });
            ((!) sfs).on_received_sources(counterpart, conversation, "share-origin-id", "file-share-id", pending_sources);

            DateTime now = new DateTime.now_utc();
            var message = new Dino.Entities.Message(null);
            message.account = account;
            message.stanza_id = "share-origin-id";
            message.counterpart = counterpart;
            message.ourpart = account.bare_jid;
            message.direction = Dino.Entities.Message.DIRECTION_RECEIVED;
            message.type_ = Dino.Entities.Message.Type.CHAT;
            message.time = now;
            message.local_time = now;
            message.encryption = Dino.Entities.Encryption.NONE;
            stream_interactor.get_module<Dino.MessageStorage>(Dino.MessageStorage.IDENTITY).add_message(message, conversation);

            var metadata = new Xmpp.Xep.FileMetadataElement.FileMetadata() {
                name = "plain.bin",
                mime_type = "application/octet-stream",
                size = 4
            };

            MainLoop loop = new MainLoop();
            ((!) sfs).create_file_transfer.begin(conversation, message, "file-share-id", metadata, null, null, (obj, res) => {
                ((!) sfs).create_file_transfer.end(res);
                loop.quit();
            });
            loop.run();

            Dino.FileTransferStorage? storage = stream_interactor.get_module<Dino.FileTransferStorage>(Dino.FileTransferStorage.IDENTITY);
            fail_if(storage == null, "test setup must start FileTransferStorage");
            Dino.Entities.FileTransfer? loaded = ((!) storage).get_file_by_message_id(message.id, conversation);
            fail_if(loaded == null, "SFS transfer must be persisted for the target message");
            fail_if(((!) loaded).message_db_id != message.id,
                "SFS transfer persistence must keep the announcing message relation outside transport info");
            fail_if(((!) loaded).sfs_sources.size != 1,
                "pending source attachment must be replayed onto the transfer when the share arrives");
            var http_source = ((!) loaded).sfs_sources[0] as Xmpp.Xep.StatelessFileSharing.HttpSource;
            fail_if(http_source == null, "replayed source must keep its HTTP source type");
            fail_if_not_eq_str("https://example.test/plain.bin", ((!) http_source).url,
                "replayed source must keep the original download URL");
        } catch (Error e) {
            fail_if_reached(@"SFS pending source replay audit failed: $(e.message)");
        } finally {
            if (application != null && GLib.Application.get_default() == (!) application) {
                GLib.Application.set_default(previous_application);
            }
            if (db != null) {
                ((!) db).close();
            }
            FileUtils.remove(db_path);
            DirUtils.remove(temp_dir);
        }
    }

    private void test_sfs_plain_http_usable_for_unencrypted_transfer() {
        var ft = make_sfs_transfer(Dino.Entities.Encryption.NONE);
        ft.sfs_sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url = "https://example.test/plain.bin" });

        fail_if(!ft.has_usable_download_source(TEST_SFS_PROVIDER_ID),
            "Unencrypted SFS transfers may use a plain HTTP source");
    }

    private void test_sfs_plain_http_rejected_for_encrypted_transfer() {
        Dino.Entities.Encryption[] encrypted_modes = {
            Dino.Entities.Encryption.OMEMO,
            Dino.Entities.Encryption.PGP
        };

        foreach (Dino.Entities.Encryption encryption in encrypted_modes) {
            var ft = make_sfs_transfer(encryption);
            ft.sfs_sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url = "https://example.test/plain.bin" });

            fail_if(ft.has_usable_download_source(TEST_SFS_PROVIDER_ID),
                "Encrypted SFS transfers must not advertise plain HTTP as downloadable");
        }
    }

    private void test_sfs_esfs_valid_gcm_for_encrypted_transfer() {
        Dino.Entities.Encryption[] encrypted_modes = {
            Dino.Entities.Encryption.OMEMO,
            Dino.Entities.Encryption.PGP
        };

        foreach (Dino.Entities.Encryption encryption in encrypted_modes) {
            assert_esfs_usable(encryption, make_gcm_esfs_source(12),
                "AES-256-GCM ESFS with a 12-byte IV should be downloadable");
            assert_esfs_usable(encryption, make_gcm_esfs_source(16),
                "AES-256-GCM ESFS with a 16-byte IV should stay downloadable for compatibility");
            assert_esfs_usable(encryption,
                make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(12, 64), "  URN:XMPP:CIPHERS:AES-256-GCM-NOPADDING:0  "),
                "AES-256-GCM ESFS should accept case and surrounding-space normalized cipher URIs");
        }
    }

    private void test_sfs_esfs_rejects_wrong_key_length() {
        assert_esfs_rejected(Dino.Entities.Encryption.OMEMO,
            make_custom_esfs_source("https://example.test/encrypted.bin", make_bytes(31, 1), make_bytes(12, 64), ESFS_GCM_CIPHER),
            "AES-256-GCM ESFS with a short key must not be considered usable");
        assert_esfs_rejected(Dino.Entities.Encryption.PGP,
            make_custom_esfs_source("https://example.test/encrypted.bin", make_bytes(33, 1), make_bytes(12, 64), ESFS_GCM_CIPHER),
            "AES-256-GCM ESFS with a long key must not be considered usable");
    }

    private void test_sfs_esfs_rejects_wrong_iv_length() {
        assert_esfs_rejected(Dino.Entities.Encryption.OMEMO,
            make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(8, 64), ESFS_GCM_CIPHER),
            "AES-256-GCM ESFS with an unsupported IV length must not be considered usable");
        assert_esfs_rejected(Dino.Entities.Encryption.PGP,
            make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(17, 64), ESFS_GCM_CIPHER),
            "AES-256-GCM ESFS with a long IV must not be considered usable");
    }

    private void test_sfs_esfs_rejects_cbc_without_hash_context() {
        Dino.Entities.Encryption[] encrypted_modes = {
            Dino.Entities.Encryption.OMEMO,
            Dino.Entities.Encryption.PGP
        };

        foreach (Dino.Entities.Encryption encryption in encrypted_modes) {
            assert_esfs_rejected(encryption, make_cbc_esfs_source(),
                "AES-256-CBC ESFS must not be considered usable without a supported hash context");
        }
    }

    private void test_sfs_esfs_rejects_unknown_and_substring_ciphers() {
        assert_esfs_rejected(Dino.Entities.Encryption.OMEMO,
            make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(12, 64), "urn:xmpp:ciphers:aes-128-gcm-nopadding:0"),
            "ESFS sources with unsupported ciphers must not be considered usable");
        assert_esfs_rejected(Dino.Entities.Encryption.OMEMO,
            make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(12, 64), ESFS_SUBSTRING_GCM_CIPHER),
            "ESFS sources with misleading GCM substring ciphers must not be considered usable");
        assert_esfs_rejected(Dino.Entities.Encryption.PGP,
            make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(16, 64), ESFS_SUBSTRING_CBC_CIPHER),
            "ESFS sources with misleading CBC substring ciphers must not be considered usable");
    }

    private void test_sfs_invalid_esfs_rejected_for_encrypted_transfer() {
        var missing_cipher = make_sfs_transfer(Dino.Entities.Encryption.OMEMO);
        missing_cipher.sfs_sources.add(make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(12, 64), ""));
        fail_if(missing_cipher.has_usable_download_source(TEST_SFS_PROVIDER_ID),
            "ESFS sources without a cipher must not be considered usable");

        var missing_key = make_sfs_transfer(Dino.Entities.Encryption.PGP);
        missing_key.sfs_sources.add(make_custom_esfs_source("https://example.test/encrypted.bin", new uint8[0], make_bytes(12, 64), ESFS_GCM_CIPHER));
        fail_if(missing_key.has_usable_download_source(TEST_SFS_PROVIDER_ID),
            "ESFS sources without a key must not be considered usable");

        var invalid_url = make_sfs_transfer(Dino.Entities.Encryption.OMEMO);
        invalid_url.sfs_sources.add(make_custom_esfs_source("file:///tmp/encrypted.bin", make_esfs_key(), make_bytes(12, 64), ESFS_GCM_CIPHER));
        fail_if(invalid_url.has_usable_download_source(TEST_SFS_PROVIDER_ID),
            "ESFS sources without an HTTP URL must not be considered usable");
    }

    private void test_sfs_sent_and_legacy_transfers_stay_usable() {
        var local_sent = make_sfs_transfer(Dino.Entities.Encryption.OMEMO);
        local_sent.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        local_sent.path = "persisted-local-copy.enc";
        fail_if(!local_sent.has_usable_download_source(TEST_SFS_PROVIDER_ID),
            "Sent transfers with a local stored copy should stay openable from local storage");

        var remote_sent_without_source = make_sfs_transfer(Dino.Entities.Encryption.NONE);
        remote_sent_without_source.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        remote_sent_without_source.path = "";
        fail_if(remote_sent_without_source.has_usable_download_source(TEST_SFS_PROVIDER_ID),
            "Own sent SFS transfers from another device without a local copy need a real remote source");

        var remote_sent_with_source = make_sfs_transfer(Dino.Entities.Encryption.NONE);
        remote_sent_with_source.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        remote_sent_with_source.path = "";
        remote_sent_with_source.sfs_sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url = "https://example.test/own-device.bin" });
        fail_if(!remote_sent_with_source.has_usable_download_source(TEST_SFS_PROVIDER_ID),
            "Own sent SFS transfers from another device with a usable source should be downloadable");
        fail_if(!remote_sent_with_source.can_start_receive_attempt(TEST_SFS_PROVIDER_ID),
            "Own sent SFS transfers from another device should be allowed to start the receive pipeline");

        var encrypted_remote_sent = make_sfs_transfer(Dino.Entities.Encryption.OMEMO);
        encrypted_remote_sent.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        encrypted_remote_sent.path = "";
        encrypted_remote_sent.sfs_sources.add(make_esfs_source());
        fail_if(!encrypted_remote_sent.has_usable_download_source(TEST_SFS_PROVIDER_ID),
            "Own encrypted sent SFS transfers from another device with ESFS should be downloadable");
        fail_if(!encrypted_remote_sent.can_start_receive_attempt(TEST_SFS_PROVIDER_ID),
            "Own encrypted sent SFS transfers from another device should be allowed to start the receive pipeline");

        var remote_sent_legacy_url = new Dino.Entities.FileTransfer();
        remote_sent_legacy_url.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        remote_sent_legacy_url.provider = 0;
        remote_sent_legacy_url.path = "";
        remote_sent_legacy_url.info = "url:aesgcm://upload.example.test/file.bin#00112233445566778899aabbccddeeff";
        fail_if(!remote_sent_legacy_url.is_sent_remote_download_offer(TEST_SFS_PROVIDER_ID, 0),
            "Own sent legacy HTTP/aesgcm transfers from another device should be treated as remote download offers");
        fail_if(!remote_sent_legacy_url.can_start_receive_attempt(TEST_SFS_PROVIDER_ID, 0),
            "Own sent legacy HTTP/aesgcm transfers from another device should be allowed to start the receive pipeline");

        var legacy = new Dino.Entities.FileTransfer();
        legacy.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
        legacy.provider = 0;
        legacy.encryption = Dino.Entities.Encryption.OMEMO;
        fail_if(!legacy.has_usable_download_source(TEST_SFS_PROVIDER_ID),
            "Non-SFS providers keep their existing source handling");
    }

    private void test_transient_provider_source_requires_live_offer() {
        var direct = new Dino.Entities.FileTransfer();
        direct.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
        direct.provider = TEST_TRANSIENT_PROVIDER_ID;
        direct.state = Dino.Entities.FileTransfer.State.NOT_STARTED;

        fail_if(direct.has_usable_download_source(TEST_SFS_PROVIDER_ID, TEST_TRANSIENT_PROVIDER_ID),
            "Transient providers must not be treated as downloadable before a live offer is registered");

        direct.set_transient_download_source_available(true);
        fail_if(!direct.has_usable_download_source(TEST_SFS_PROVIDER_ID, TEST_TRANSIENT_PROVIDER_ID),
            "Transient providers may be downloaded only while their live offer is registered");

        direct.set_transient_download_source_available(false);
        fail_if(direct.has_usable_download_source(TEST_SFS_PROVIDER_ID, TEST_TRANSIENT_PROVIDER_ID),
            "Transient providers must become unavailable again after the live offer expires");
    }

    private void test_sfs_auto_download_requires_usable_source() {
        var plain = make_sfs_transfer(Dino.Entities.Encryption.NONE);
        plain.size = 4096;
        plain.sfs_sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url = "https://example.test/plain.bin" });
        fail_if(!plain.is_auto_download_candidate(TEST_SFS_PROVIDER_ID, TEST_AUTO_DOWNLOAD_MAX_BYTES),
            "Unencrypted SFS transfers with HTTP sources may auto-download");

        var encrypted_plain = make_sfs_transfer(Dino.Entities.Encryption.OMEMO);
        encrypted_plain.size = 4096;
        encrypted_plain.sfs_sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url = "https://example.test/plain.bin" });
        fail_if(encrypted_plain.is_auto_download_candidate(TEST_SFS_PROVIDER_ID, TEST_AUTO_DOWNLOAD_MAX_BYTES),
            "Encrypted SFS transfers must not auto-download from plain HTTP sources");

        var encrypted_esfs = make_sfs_transfer(Dino.Entities.Encryption.PGP);
        encrypted_esfs.size = 4096;
        encrypted_esfs.sfs_sources.add(make_esfs_source());
        fail_if(!encrypted_esfs.is_auto_download_candidate(TEST_SFS_PROVIDER_ID, TEST_AUTO_DOWNLOAD_MAX_BYTES),
            "Encrypted SFS transfers with ESFS sources may auto-download");

        var oversized = make_sfs_transfer(Dino.Entities.Encryption.NONE);
        oversized.size = TEST_AUTO_DOWNLOAD_MAX_BYTES;
        oversized.sfs_sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url = "https://example.test/large.bin" });
        fail_if(oversized.is_auto_download_candidate(TEST_SFS_PROVIDER_ID, TEST_AUTO_DOWNLOAD_MAX_BYTES),
            "Transfers at or above the auto-download limit must not auto-download");

        var own_remote = make_sfs_transfer(Dino.Entities.Encryption.NONE);
        own_remote.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        own_remote.path = "";
        own_remote.size = 4096;
        own_remote.sfs_sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url = "https://example.test/own-device.bin" });
        fail_if(!own_remote.is_auto_download_candidate(TEST_SFS_PROVIDER_ID, TEST_AUTO_DOWNLOAD_MAX_BYTES),
            "Small own sent SFS transfers from another device with a usable source may auto-download");

        var own_remote_encrypted = make_sfs_transfer(Dino.Entities.Encryption.OMEMO);
        own_remote_encrypted.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        own_remote_encrypted.path = "";
        own_remote_encrypted.size = 4096;
        own_remote_encrypted.sfs_sources.add(make_esfs_source());
        fail_if(!own_remote_encrypted.is_auto_download_candidate(TEST_SFS_PROVIDER_ID, TEST_AUTO_DOWNLOAD_MAX_BYTES),
            "Small own encrypted sent SFS transfers from another device with ESFS may auto-download");

        var own_local = make_sfs_transfer(Dino.Entities.Encryption.NONE);
        own_local.direction = Dino.Entities.FileTransfer.DIRECTION_SENT;
        own_local.path = "persisted-local-copy.enc";
        own_local.size = 4096;
        fail_if(own_local.is_auto_download_candidate(TEST_SFS_PROVIDER_ID, TEST_AUTO_DOWNLOAD_MAX_BYTES),
            "Local sent transfers with a stored copy must not be treated as receive auto-download candidates");
    }

    private Dino.Entities.FileTransfer make_sfs_transfer(Dino.Entities.Encryption encryption) {
        var ft = new Dino.Entities.FileTransfer();
        ft.direction = Dino.Entities.FileTransfer.DIRECTION_RECEIVED;
        ft.provider = TEST_SFS_PROVIDER_ID;
        ft.encryption = encryption;
        return ft;
    }

    private Xmpp.Xep.StatelessFileSharing.EsfsHttpSource make_esfs_source() {
        return make_gcm_esfs_source(12);
    }

    private Xmpp.Xep.StatelessFileSharing.EsfsHttpSource make_gcm_esfs_source(int iv_length) {
        return make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(iv_length, 64), ESFS_GCM_CIPHER);
    }

    private Xmpp.Xep.StatelessFileSharing.EsfsHttpSource make_cbc_esfs_source() {
        return make_custom_esfs_source("https://example.test/encrypted.bin", make_esfs_key(), make_bytes(16, 64), ESFS_CBC_CIPHER);
    }

    private Xmpp.Xep.StatelessFileSharing.EsfsHttpSource make_custom_esfs_source(string url, uint8[] key, uint8[] iv, string cipher_uri) {
        var source = new Xmpp.Xep.StatelessFileSharing.EsfsHttpSource();
        source.url = url;
        source.key = key;
        source.iv = iv;
        source.cipher_uri = cipher_uri;
        return source;
    }

    private void assert_esfs_usable(Dino.Entities.Encryption encryption, Xmpp.Xep.StatelessFileSharing.EsfsHttpSource source, string reason) {
        var ft = make_sfs_transfer(encryption);
        ft.sfs_sources.add(source);
        fail_if(!ft.has_usable_download_source(TEST_SFS_PROVIDER_ID), reason);
    }

    private void assert_esfs_rejected(Dino.Entities.Encryption encryption, Xmpp.Xep.StatelessFileSharing.EsfsHttpSource source, string reason) {
        var ft = make_sfs_transfer(encryption);
        ft.sfs_sources.add(source);
        fail_if(ft.has_usable_download_source(TEST_SFS_PROVIDER_ID), reason);
    }

    private uint8[] make_esfs_key() {
        return make_bytes(32, 1);
    }

    private uint8[] make_bytes(int length, int seed) {
        uint8[] bytes = new uint8[length];
        for (int i = 0; i < length; i++) {
            bytes[i] = (uint8) ((seed + i) % 251);
        }
        return bytes;
    }

    private class SfsPendingTestApplication : GLib.Application, Dino.Application {
        public Dino.Database db { get; set; }
        public string? db_key { get; set; }
        public Dino.Security.FileEncryption file_encryption { get; set; }
        public Dino.Entities.Settings settings { get; set; }
        public Dino.StreamInteractor stream_interactor { get; set; }
        public Dino.Plugins.Registry plugin_registry { get; set; default = new Dino.Plugins.Registry(); }
        public Dino.SearchPathGenerator? search_path_generator { get; set; }

        public SfsPendingTestApplication(Dino.Database db, Dino.StreamInteractor stream_interactor) {
            Object(application_id: "im.dinox.sfs-pending-test", flags: GLib.ApplicationFlags.NON_UNIQUE);
            this.db = db;
            this.db_key = "sfs-pending-source-test";
            this.file_encryption = new Dino.Security.FileEncryption((!) this.db_key);
            this.settings = new Dino.Entities.Settings.from_db(db);
            this.stream_interactor = stream_interactor;
        }

        public void handle_uri(string jid, string query, Gee.Map<string, string> options) {
        }
    }
}

}
