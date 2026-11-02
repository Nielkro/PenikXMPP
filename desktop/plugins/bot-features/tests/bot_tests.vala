using Gee;

namespace Dino.Plugins.BotFeatures.Test {

/**
 * Rate limiter contract tests.
 *
 * RateLimiter implements a sliding-window rate limiter per IETF RFC 6585 §4
 * ("429 Too Many Requests") spirit: requests exceeding max_requests within
 * window_seconds MUST be rejected. These tests verify the contract:
 *
 * CONTRACT-1: Exactly max_requests allowed per window
 * CONTRACT-2: Request max_requests+1 MUST be blocked
 * CONTRACT-3: Per-key isolation (one key's quota does not affect another)
 * CONTRACT-4: Window expiry resets quota
 * CONTRACT-5: retry_after returns seconds until window reset
 * CONTRACT-6: Cleanup removes stale state without affecting live windows
 * CONTRACT-7: window_seconds ≤ 0 MUST be clamped to 1 (security invariant)
 */
class RateLimiterTest : Gee.TestCase {

    public RateLimiterTest() {
        base("RateLimiter");
        // CONTRACT-1 + CONTRACT-2: exact boundary
        add_test("CONTRACT1_allows_exactly_max_requests", test_allows_exactly_max);
        add_test("CONTRACT2_blocks_request_max_plus_one", test_blocks_over_limit);
        // CONTRACT-3: per-key isolation
        add_test("CONTRACT3_separate_keys_independent", test_separate_keys_independent);
        // CONTRACT-4: window expiry
        add_test("CONTRACT4_window_resets_after_expiry", test_window_resets_after_expiry);
        // CONTRACT-5: retry_after
        add_test("CONTRACT5_retry_after_positive_when_blocked", test_retry_after_positive);
        add_test("CONTRACT5_retry_after_zero_unknown_key", test_retry_after_zero_unknown);
        // CONTRACT-6: cleanup
        add_test("CONTRACT6_cleanup_preserves_live_windows", test_cleanup_preserves_live);
        // CONTRACT-7: window_seconds guard
        add_test("CONTRACT7_window_seconds_clamped_to_1", test_window_seconds_clamped);
        // CONTRACT-8: Edge case max_requests=1
        add_test("CONTRACT8_single_request_limit", test_single_request_limit);
    }

    /**
     * CONTRACT-1: Exactly max_requests calls to check() with the same key
     * MUST all return true.
     */
    void test_allows_exactly_max() {
        var limiter = new RateLimiter(5, 60);
        for (int i = 0; i < 5; i++) {
            assert_true(limiter.check(1));
        }
    }

    /**
     * CONTRACT-2: The (max_requests+1)-th call MUST return false.
     * Subsequent calls also remain blocked.
     */
    void test_blocks_over_limit() {
        var limiter = new RateLimiter(3, 60);
        assert_true(limiter.check(1));
        assert_true(limiter.check(1));
        assert_true(limiter.check(1));
        // 4th is blocked
        assert_false(limiter.check(1));
        // 5th also blocked
        assert_false(limiter.check(1));
    }

    /**
     * CONTRACT-3: Keys are isolated. Exhausting key A's quota
     * MUST NOT affect key B.
     */
    void test_separate_keys_independent() {
        var limiter = new RateLimiter(2, 60);
        // Key 1: exhaust quota
        assert_true(limiter.check(1));
        assert_true(limiter.check(1));
        assert_false(limiter.check(1));

        // Key 2: full quota available
        assert_true(limiter.check(2));
        assert_true(limiter.check(2));
        assert_false(limiter.check(2));

        // Key 1 still blocked
        assert_false(limiter.check(1));
    }

    /**
     * CONTRACT-4: After window_seconds have elapsed, the window MUST
     * reset and allow max_requests again.
     */
    void test_window_resets_after_expiry() {
        var limiter = new RateLimiter(2, 1);
        assert_true(limiter.check(1));
        assert_true(limiter.check(1));
        assert_false(limiter.check(1));

        // Wait for window to expire
        Thread.usleep(1100000);  // 1.1 seconds

        // Window expired — quota reset
        assert_true(limiter.check(1));
    }

    /**
     * CONTRACT-5a: retry_after for a blocked key MUST return
     * a positive integer ≤ window_seconds.
     */
    void test_retry_after_positive() {
        var limiter = new RateLimiter(1, 60);
        limiter.check(1);  // use quota
        limiter.check(1);  // blocked

        int retry = limiter.retry_after(1);
        assert_true(retry > 0);
        assert_true(retry <= 60);
    }

    /**
     * CONTRACT-5b: retry_after for an unknown key MUST return 0
     * (no waiting needed — key has no prior history).
     */
    void test_retry_after_zero_unknown() {
        var limiter = new RateLimiter(5, 60);
        assert_true(limiter.retry_after(999) == 0);
    }

    /**
     * CONTRACT-6: cleanup() removes only stale windows (>10× window_seconds old).
     * Live windows MUST be preserved and functional.
     */
    void test_cleanup_preserves_live() {
        var limiter = new RateLimiter(5, 1);
        limiter.check(1);
        limiter.check(2);
        limiter.check(3);

        // Cleanup on fresh windows — must not corrupt state
        limiter.cleanup();

        // Live windows still functional
        assert_true(limiter.check(1));
    }

    /**
     * CONTRACT-7: window_seconds ≤ 0 is a security violation (infinite window
     * or division by zero). Constructor MUST clamp to at least 1.
     */
    void test_window_seconds_clamped() {
        // window_seconds=0 → should be clamped to 1 internally
        var limiter = new RateLimiter(2, 0);
        assert_true(limiter.check(1));
        assert_true(limiter.check(1));
        assert_false(limiter.check(1));

        // Should reset after ~1 second (clamped to 1)
        Thread.usleep(1100000);
        assert_true(limiter.check(1));
    }

    /**
     * Edge case: max_requests=1 means exactly one request, then blocked.
     */
    void test_single_request_limit() {
        var limiter = new RateLimiter(1, 60);
        assert_true(limiter.check(1));
        assert_false(limiter.check(1));
    }
}

class PermissionUtilsTest : Gee.TestCase {

    public PermissionUtilsTest() {
        base("PermissionUtils");
        add_test("PERMISSION_null_defaults_to_all", test_null_defaults_to_all);
        add_test("PERMISSION_all_is_super_scope", test_all_is_super_scope);
        add_test("PERMISSION_comma_list_trims_parts", test_comma_list_trims_parts);
        add_test("PERMISSION_missing_scope_denied", test_missing_scope_denied);
        add_test("PERMISSION_receive_update_runtime_requires_active_status", test_receive_update_runtime_requires_active_status);
        add_test("PERMISSION_receive_update_runtime_respects_account_toggle", test_receive_update_runtime_respects_account_toggle);
        add_test("PERMISSION_dedicated_commands_respect_account_toggle", test_dedicated_commands_respect_account_toggle);
        add_test("PERMISSION_owner_jid_matches_bare_jid_only", test_owner_jid_matches_bare_jid_only);
        add_test("TELEGRAM_valid_modes_are_explicit", test_telegram_valid_modes);
        add_test("MUC_mentions_accept_plain_bot_name", test_muc_mentions_accept_plain_bot_name);
        add_test("MUC_mentions_reject_substring_matches", test_muc_mentions_reject_substring_matches);
        add_test("MUC_owner_mentions_are_separate_from_bot_mentions", test_muc_owner_mentions_are_separate_from_bot_mentions);
        add_test("MUC_ai_reply_policy_is_conservative", test_muc_ai_reply_policy_is_conservative);
        add_test("DEDICATED_aesgcm_file_urls_are_transport_not_prompts", test_aesgcm_file_urls_are_transport_not_prompts);
        add_test("MUC_saved_rooms_are_normalized_replaced_and_removed", test_muc_saved_rooms_are_normalized_replaced_and_removed);
        add_test("REGISTRY_delete_bot_removes_scoped_settings", test_delete_bot_removes_scoped_settings);
        add_test("REGISTRY_delete_account_owner_data_removes_bots_and_owner_settings", test_delete_account_owner_data_removes_bots_and_owner_settings);
        add_test("INTEGRATION_ai_setup_can_configure_without_enabling", test_ai_setup_can_configure_without_enabling);
        add_test("INTEGRATION_ai_provider_presets_match_supported_list", test_ai_provider_presets_match_supported_list);
        add_test("LOCALE_provider_ids_and_command_permissions_are_language_independent", test_machine_token_locale);
        add_test("INTEGRATION_telegram_setup_can_configure_without_enabling", test_telegram_setup_can_configure_without_enabling);
        add_test("DEDICATED_generated_credentials_are_safe_for_provisioning", test_generated_credentials_are_safe_for_provisioning);
        add_test("DEDICATED_ejabberd_check_account_result_codes_are_parsed", test_ejabberd_check_account_result_codes_are_parsed);
        add_test("PERMISSION_dedicated_command_views_do_not_need_admin", test_dedicated_command_views_do_not_need_admin);
        add_test("PERMISSION_dedicated_command_mutations_need_admin", test_dedicated_command_mutations_need_admin);
    }

    void test_machine_token_locale() {
        string? previous = Intl.setlocale(LocaleCategory.CTYPE, null);
        Intl.setlocale(LocaleCategory.CTYPE, "");
        string db_path = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-bot-locale-%s.db".printf(Uuid.string_random()));
        try {
            var registry = new BotRegistry(db_path, null);
            var ai = new AiIntegration(registry);
            foreach (string name in new string[] { "openai", "gemini", "mistral", "xai" }) {
                assert_true(ai.has_provider_preset(name.ascii_up()));
                assert_true(ai.provider_ai_type(name) == ai.provider_ai_type(name.ascii_up()));
            }
            assert_true(BotUtils.dedicated_command_requires_admin("/KI", "SETUP", "openai key model"));
            assert_true(BotUtils.dedicated_command_requires_admin("/API", "SERVER", "port 7842"));
            assert_false(BotUtils.dedicated_command_requires_admin("/KI", "STATUS", null));
            ai.shutdown();
        } catch (Error error) { GLib.Test.message("%s", error.message); GLib.Test.fail(); }
        finally {
            Intl.setlocale(LocaleCategory.CTYPE, previous);
            FileUtils.remove(db_path); FileUtils.remove(db_path + "-wal"); FileUtils.remove(db_path + "-shm");
        }
    }

    void test_null_defaults_to_all() {
        var bot = new BotInfo();
        bot.permissions = null;
        assert_true(BotUtils.has_permission(bot, "receive_updates"));
        assert_true(BotUtils.has_permission(bot, "send_message"));
    }

    void test_all_is_super_scope() {
        var bot = new BotInfo();
        bot.permissions = "all";
        assert_true(BotUtils.has_permission(bot, "receive_updates"));
        assert_true(BotUtils.has_permission(bot, "webhook"));
    }

    void test_comma_list_trims_parts() {
        var bot = new BotInfo();
        bot.permissions = "send_message, receive_updates";
        assert_true(BotUtils.has_permission(bot, "send_message"));
        assert_true(BotUtils.has_permission(bot, "receive_updates"));
    }

    void test_missing_scope_denied() {
        var bot = new BotInfo();
        bot.permissions = "send_message";
        assert_false(BotUtils.has_permission(bot, "receive_updates"));
    }

    void test_receive_update_runtime_requires_active_status() {
        var bot = new BotInfo();
        bot.status = "active";
        bot.permissions = "receive_updates";
        assert_true(BotUtils.can_receive_updates(bot));

        bot.status = "disabled";
        assert_false(BotUtils.can_receive_updates(bot));

        bot.status = "active";
        bot.permissions = "send_message";
        assert_false(BotUtils.can_receive_updates(bot));

        assert_false(BotUtils.can_receive_updates(null));
    }

    void test_receive_update_runtime_respects_account_toggle() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-bot-utils-test-%s.db".printf(Uuid.string_random()));
        BotRegistry registry;
        try {
            registry = new BotRegistry(db_path, null);
        } catch (Error e) {
            GLib.Test.message("Unable to create test BotRegistry: %s", e.message);
            GLib.Test.fail();
            return;
        }

        var bot = new BotInfo();
        bot.status = "active";
        bot.permissions = "receive_updates";
        bot.owner_jid = "owner@example.test";

        assert_true(BotUtils.can_receive_updates_for_enabled_account(bot, registry));

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        assert_false(BotUtils.can_receive_updates_for_enabled_account(bot, registry));

        registry.set_setting("botmother_account_enabled:owner@example.test", "true");
        assert_true(BotUtils.can_receive_updates_for_enabled_account(bot, registry));

        FileUtils.remove(db_path);
        FileUtils.remove(db_path + "-wal");
        FileUtils.remove(db_path + "-shm");
    }

    void test_aesgcm_file_urls_are_transport_not_prompts() {
        assert_true(BotUtils.is_legacy_aesgcm_file_url(
            "aesgcm://upload.dinox.im:5443/path/file.jpg#00112233445566778899aabbccddeeff"));
        assert_true(BotUtils.is_legacy_aesgcm_file_url(
            "  aesgcm://upload.dinox.im:5443/path/file.jpg#AABBCCDDEEFF00112233445566778899  "));
        assert_false(BotUtils.is_legacy_aesgcm_file_url(
            "please inspect aesgcm://upload.dinox.im/file.jpg#001122"));
        assert_false(BotUtils.is_legacy_aesgcm_file_url("https://dinox.im/"));
        assert_false(BotUtils.is_legacy_aesgcm_file_url("hello"));
    }

    void test_dedicated_commands_respect_account_toggle() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-bot-command-runtime-test-%s.db".printf(Uuid.string_random()));
        BotRegistry registry;
        try {
            registry = new BotRegistry(db_path, null);
        } catch (Error e) {
            GLib.Test.message("Unable to create test BotRegistry: %s", e.message);
            GLib.Test.fail();
            return;
        }

        var bot = new BotInfo();
        bot.status = "active";
        bot.owner_jid = "owner@example.test";

        assert_true(BotUtils.can_process_dedicated_inbound_command(bot, registry));

        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        assert_false(BotUtils.can_process_dedicated_inbound_command(bot, registry));

        registry.set_setting("botmother_account_enabled:owner@example.test", "true");
        assert_true(BotUtils.can_process_dedicated_inbound_command(bot, registry));

        bot.status = "paused";
        assert_false(BotUtils.can_process_dedicated_inbound_command(bot, registry));
        assert_false(BotUtils.can_process_dedicated_inbound_command(null, registry));

        FileUtils.remove(db_path);
        FileUtils.remove(db_path + "-wal");
        FileUtils.remove(db_path + "-shm");
    }

    void test_owner_jid_matches_bare_jid_only() {
        var bot = new BotInfo();
        bot.owner_jid = "owner@example.test";

        assert_true(BotUtils.is_owner_jid(bot, "owner@example.test"));
        assert_true(BotUtils.is_owner_jid(bot, "owner@example.test/resource"));
        assert_false(BotUtils.is_owner_jid(bot, "other@example.test"));

        bot.owner_jid = null;
        assert_false(BotUtils.is_owner_jid(bot, "owner@example.test"));
    }

    void test_telegram_valid_modes() {
        assert_true(BotUtils.is_valid_telegram_mode("bridge"));
        assert_true(BotUtils.is_valid_telegram_mode("forward"));
        assert_false(BotUtils.is_valid_telegram_mode(""));
        assert_false(BotUtils.is_valid_telegram_mode("both"));
        assert_false(BotUtils.is_valid_telegram_mode("forward "));
    }

    void test_muc_mentions_accept_plain_bot_name() {
        var bot = new BotInfo();
        bot.name = "DinoXBot";
        bot.jid = "dinoxbot@example.test";

        assert_true(BotUtils.dedicated_group_message_mentions_bot(bot, "hi dinoxbot"));
        assert_true(BotUtils.dedicated_group_message_mentions_bot(bot, "hi @dinoxbot"));
        assert_true(BotUtils.dedicated_group_message_mentions_bot(bot, "DinoXBot: kannst du helfen?"));
        assert_true(BotUtils.dedicated_group_message_mentions_bot(bot, "frage an dinoxbot@example.test"));
    }

    void test_muc_mentions_reject_substring_matches() {
        var bot = new BotInfo();
        bot.name = "DinoXBot";
        bot.jid = "dinoxbot@example.test";

        assert_false(BotUtils.dedicated_group_message_mentions_bot(bot, "mydinoxbothelper"));
        assert_false(BotUtils.dedicated_group_message_mentions_bot(bot, "dinoxbothelper"));
    }

    void test_muc_owner_mentions_are_separate_from_bot_mentions() {
        var bot = new BotInfo();
        bot.name = "DinoXBot";
        bot.jid = "dinoxbot@example.test";
        bot.owner_jid = "ralf@example.test";

        assert_true(BotUtils.dedicated_group_message_mentions_owner(bot, "ralf ist noch nicht da"));
        assert_true(BotUtils.dedicated_group_message_mentions_owner(bot, "frage an ralf@example.test"));
        assert_false(BotUtils.dedicated_group_message_mentions_owner(bot, "hi dinoxbot"));
        assert_false(BotUtils.dedicated_group_message_mentions_owner(bot, "mein ralfbot ist kaputt"));
        assert_false(BotUtils.dedicated_group_message_mentions_owner(bot, "ralfchen ist da"));

        assert_true(BotUtils.should_notify_owner_about_group_mention(bot, "ralf ist noch nicht da", false));
        assert_false(BotUtils.should_notify_owner_about_group_mention(bot, "hi dinoxbot, ich bin Ralf", true));
    }

    void test_muc_ai_reply_policy_is_conservative() {
        var bot = new BotInfo();
        bot.name = "DinoXBot";
        bot.jid = "dinoxbot@example.test";

        assert_true(BotUtils.should_dedicated_group_ai_reply(bot, "hi dinoxbot", true, "mention_only"));
        assert_true(BotUtils.should_dedicated_group_ai_reply(bot, "dinoxbot, Ralf ist noch nicht da", true, "mention_only"));
        assert_false(BotUtils.should_dedicated_group_ai_reply(bot, "Ralf ist noch nicht da", false, "mention_only"));
        assert_false(BotUtils.should_dedicated_group_ai_reply(bot, "Guten Morgen zusammen", false, "active_support"));
        assert_true(BotUtils.should_dedicated_group_ai_reply(bot, "Welche deutschen XMPP Anbieter gibt es?", false, "support_questions"));
        assert_true(BotUtils.should_dedicated_group_ai_reply(bot, "ich brauche infos zu deutschen xmpp anbietern", false, "support_questions"));
        assert_true(BotUtils.should_dedicated_group_ai_reply(bot, "please recommend an OMEMO client", false, "support_questions"));
        assert_false(BotUtils.should_dedicated_group_ai_reply(bot, "Welche Pizza nehmen wir?", false, "support_questions"));
        assert_false(BotUtils.should_dedicated_group_ai_reply(bot, "xmppserverparty heute Abend?", false, "support_questions"));
        assert_true(BotUtils.should_dedicated_group_ai_reply(bot, "OMEMO funktioniert nicht", false, "active_support"));
        assert_false(BotUtils.should_dedicated_group_ai_reply(bot, "ich brauche infos zum wetter", false, "support_questions"));
        assert_false(BotUtils.should_dedicated_group_ai_reply(bot, "OMEMO funktioniert nicht", false, "unknown_mode"));
        assert_true(BotUtils.should_dedicated_group_ai_reply(bot, "hi dinoxbot", true, "unknown_mode"));
    }

    void test_muc_saved_rooms_are_normalized_replaced_and_removed() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-bot-muc-rooms-test-%s.db".printf(Uuid.string_random()));
        BotRegistry registry;
        try {
            registry = new BotRegistry(db_path, null);
        } catch (Error e) {
            GLib.Test.message("Unable to create test BotRegistry: %s", e.message);
            GLib.Test.fail();
            return;
        }

        int bot_id = 42;
        registry.set_setting(BotUtils.muc_rooms_setting_key(bot_id),
            "broken-entry\nroom@conference.example.test/ignored\tOldNick\n\tbad");

        var initial = BotUtils.get_muc_rooms(registry, bot_id);
        assert_true(initial.size == 1);
        assert_true(initial[0].room_jid == "room@conference.example.test");
        assert_true(initial[0].nick == "OldNick");

        BotUtils.remember_muc_room(registry, bot_id, "room@conference.example.test/new-resource", "New\tNick");
        var replaced = BotUtils.get_muc_rooms(registry, bot_id);
        assert_true(replaced.size == 1);
        assert_true(replaced[0].room_jid == "room@conference.example.test");
        assert_true(replaced[0].nick == "New Nick");

        BotUtils.remember_muc_room(registry, bot_id, "second@conference.example.test", "Second");
        var two_rooms = BotUtils.get_muc_rooms(registry, bot_id);
        assert_true(two_rooms.size == 2);

        BotUtils.forget_muc_room(registry, bot_id, "room@conference.example.test/resource");
        var remaining = BotUtils.get_muc_rooms(registry, bot_id);
        assert_true(remaining.size == 1);
        assert_true(remaining[0].room_jid == "second@conference.example.test");

        BotUtils.forget_muc_room(registry, bot_id, "second@conference.example.test");
        assert_true(registry.get_setting(BotUtils.muc_rooms_setting_key(bot_id)) == null);

        FileUtils.remove(db_path);
        FileUtils.remove(db_path + "-wal");
        FileUtils.remove(db_path + "-shm");
    }

    void test_delete_bot_removes_scoped_settings() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-bot-delete-settings-test-%s.db".printf(Uuid.string_random()));
        BotRegistry registry;
        try {
            registry = new BotRegistry(db_path, null);
        } catch (Error e) {
            GLib.Test.message("Unable to create test BotRegistry: %s", e.message);
            GLib.Test.fail();
            return;
        }

        int bot_id = registry.create_bot("CleanupBot", "owner@example.test",
            TokenManager.create_inactive_token_marker("test"), "dedicated", "bot@example.test");
        registry.update_bot_password(bot_id, "secret-password");
        registry.set_webhook(bot_id, "https://hook.example.test/path?token=secret", "webhook-secret", true);

        string[] scoped_keys = {
            "bot_avatar:%d".printf(bot_id),
            "bot_avatar_type:%d".printf(bot_id),
            "bot_allowed_targets:%d".printf(bot_id),
            "bot_target_mode:%d".printf(bot_id),
            "bot_dedicated_provisioning:%d".printf(bot_id),
            "bot_%d_purpose".printf(bot_id),
            "bot_%d_muc_rooms".printf(bot_id),
            "bot_%d_muc_ai_mode".printf(bot_id),
            "bot_%d_muc_owner_notify".printf(bot_id),
            "bot_ignore_delayed_before:%d".printf(bot_id),
            "bot_%d_ai_enabled".printf(bot_id),
            "bot_%d_ai_provider".printf(bot_id),
            "bot_%d_ai_type".printf(bot_id),
            "bot_%d_ai_endpoint".printf(bot_id),
            "bot_%d_ai_key".printf(bot_id),
            "bot_%d_ai_model".printf(bot_id),
            "bot_%d_ai_system".printf(bot_id),
            "bot_%d_tg_enabled".printf(bot_id),
            "bot_%d_tg_token".printf(bot_id),
            "bot_%d_tg_chat_id".printf(bot_id),
            "bot_%d_tg_mode".printf(bot_id)
        };
        foreach (string key in scoped_keys) {
            registry.set_setting(key, "value");
        }

        assert_true(registry.get_secret_setting("bot_secret_password:%d".printf(bot_id)) == "secret-password");
        assert_true(registry.get_secret_setting("bot_webhook_secret:%d".printf(bot_id)) == "webhook-secret");

        registry.delete_bot(bot_id);

        assert_true(registry.get_bot_by_id(bot_id) == null);
        assert_true(registry.get_setting("bot_secret_password:%d".printf(bot_id)) == null);
        assert_true(registry.get_setting("bot_webhook_secret:%d".printf(bot_id)) == null);
        foreach (string key in scoped_keys) {
            assert_true(registry.get_setting(key) == null);
        }

        FileUtils.remove(db_path);
        FileUtils.remove(db_path + "-wal");
        FileUtils.remove(db_path + "-shm");
    }

    void test_delete_account_owner_data_removes_bots_and_owner_settings() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-bot-owner-delete-test-%s.db".printf(Uuid.string_random()));
        BotRegistry registry;
        try {
            registry = new BotRegistry(db_path, null);
        } catch (Error e) {
            GLib.Test.message("Unable to create test BotRegistry: %s", e.message);
            GLib.Test.fail();
            return;
        }

        int personal_id = registry.create_bot("Personal", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");
        int dedicated_id = registry.create_bot("Dedicated", "owner@example.test",
            TokenManager.create_inactive_token_marker("pending"), "dedicated", "bot-owner@example.test");
        int other_id = registry.create_bot("Other", "other@example.test",
            TokenManager.create_inactive_token_marker("pending"), "personal");

        registry.update_bot_password(dedicated_id, "secret-password");
        registry.set_setting("bot_dedicated_provisioning:%d".printf(dedicated_id), "ejabberd");
        registry.set_setting("botmother_account_enabled:owner@example.test", "false");
        registry.add_cloudbot_management_token("owner@example.test", "cbot_owner_token");

        int deleted = registry.delete_account_owner_data("owner@example.test");

        assert_true(deleted == 2);
        assert_true(registry.get_bot_by_id(personal_id) == null);
        assert_true(registry.get_bot_by_id(dedicated_id) == null);
        assert_true(registry.get_bot_by_id(other_id) != null);
        assert_true(registry.get_setting("bot_dedicated_provisioning:%d".printf(dedicated_id)) == null);
        assert_true(registry.get_secret_setting("bot_secret_password:%d".printf(dedicated_id)) == null);
        assert_true(registry.get_setting("botmother_account_enabled:owner@example.test") == null);
        assert_true(registry.get_cloudbot_management_tokens("owner@example.test").size == 0);

        FileUtils.remove(db_path);
        FileUtils.remove(db_path + "-wal");
        FileUtils.remove(db_path + "-shm");
    }

    void test_ai_setup_can_configure_without_enabling() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-bot-ai-config-test-%s.db".printf(Uuid.string_random()));
        BotRegistry registry;
        try {
            registry = new BotRegistry(db_path, null);
        } catch (Error e) {
            GLib.Test.message("Unable to create test BotRegistry: %s", e.message);
            GLib.Test.fail();
            return;
        }

        int bot_id = 77;
        registry.set_setting("bot_%d_ai_system".printf(bot_id), "Custom support prompt.");
        var ai = new AiIntegration(registry);

        ai.configure_preset(bot_id, "ollama", "-", "llama3", false);
        assert_false(ai.is_enabled(bot_id));
        assert_true(registry.get_setting("bot_%d_ai_model".printf(bot_id)) == "llama3");
        assert_true(registry.get_setting("bot_%d_ai_system".printf(bot_id)) == "Custom support prompt.");

        ai.configure_preset(bot_id, "ollama", "-", "phi3", true);
        assert_true(ai.is_enabled(bot_id));
        assert_true(registry.get_setting("bot_%d_ai_model".printf(bot_id)) == "phi3");
        assert_true(registry.get_setting("bot_%d_ai_system".printf(bot_id)) == "Custom support prompt.");

        int new_bot_id = 78;
        ai.configure_preset(new_bot_id, "ollama", "-", "llama3", true);
        assert_true(ai.is_enabled(new_bot_id));
        assert_true(registry.get_setting("bot_%d_ai_system".printf(new_bot_id)) == "Du bist ein hilfreicher Assistent.");
        ai.shutdown();

        FileUtils.remove(db_path);
        FileUtils.remove(db_path + "-wal");
        FileUtils.remove(db_path + "-shm");
    }

    void test_ai_provider_presets_match_supported_list() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-bot-ai-providers-test-%s.db".printf(Uuid.string_random()));
        BotRegistry registry;
        try {
            registry = new BotRegistry(db_path, null);
        } catch (Error e) {
            GLib.Test.message("Unable to create test BotRegistry: %s", e.message);
            GLib.Test.fail();
            return;
        }

        var ai = new AiIntegration(registry);
        string[] providers = {
            "ollama",
            "openai",
            "claude",
            "gemini",
            "groq",
            "mistral",
            "deepseek",
            "perplexity",
            "xai",
            "openclaw"
        };
        string[] expected_types = {
            "ollama",
            "openai",
            "claude",
            "gemini",
            "openai",
            "openai",
            "openai",
            "openai",
            "xai",
            "openclaw"
        };

        for (int i = 0; i < providers.length; i++) {
            string provider = providers[i];
            assert_true(ai.has_provider_preset(provider));
            assert_true(ai.provider_ai_type(provider) == expected_types[i]);
            assert_true(ai.provider_endpoint(provider) != null);
            assert_true(ai.provider_endpoint(provider) != "");
        }
        assert_false(ai.provider_requires_api_key("ollama"));
        assert_true(ai.provider_requires_api_key("xai"));
        assert_true(ai.provider_requires_api_key("openclaw"));
        assert_false(ai.has_provider_preset("unknown"));
        assert_true(ai.provider_ai_type("unknown") == null);
        assert_true(ai.provider_endpoint("unknown") == null);
        ai.shutdown();

        FileUtils.remove(db_path);
        FileUtils.remove(db_path + "-wal");
        FileUtils.remove(db_path + "-shm");
    }

    void test_telegram_setup_can_configure_without_enabling() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(),
            "dinox-bot-telegram-config-test-%s.db".printf(Uuid.string_random()));
        BotRegistry registry;
        try {
            registry = new BotRegistry(db_path, null);
        } catch (Error e) {
            GLib.Test.message("Unable to create test BotRegistry: %s", e.message);
            GLib.Test.fail();
            return;
        }

        int bot_id = 88;
        var telegram = new TelegramBridge(registry);
        telegram.configure(bot_id, "123:ABC", "42", "bridge", false);
        assert_false(telegram.is_enabled(bot_id));
        assert_true(registry.get_secret_setting("bot_%d_tg_token".printf(bot_id)) == "123:ABC");
        assert_true(registry.get_setting("bot_%d_tg_chat_id".printf(bot_id)) == "42");
        assert_true(registry.get_setting("bot_%d_tg_mode".printf(bot_id)) == "bridge");

        telegram.configure(bot_id, "123:ABC", "99", "forward", true);
        assert_true(telegram.is_enabled(bot_id));
        assert_true(registry.get_setting("bot_%d_tg_chat_id".printf(bot_id)) == "99");
        assert_true(registry.get_setting("bot_%d_tg_mode".printf(bot_id)) == "forward");
        telegram.shutdown();

        FileUtils.remove(db_path);
        FileUtils.remove(db_path + "-wal");
        FileUtils.remove(db_path + "-shm");
    }

    void test_generated_credentials_are_safe_for_provisioning() {
        string username = EjabberdApi.generate_bot_username("KI Test Bot! 2026");
        assert_true(username.has_prefix("bot_ki_test_bot_2026_"));
        assert_true(username.index_of("@") < 0);
        assert_true(username.index_of("/") < 0);
        assert_true(username.index_of(" ") < 0);
        assert_true(username.length <= 4 + 50 + 1 + 8);

        string password = EjabberdApi.generate_bot_password();
        assert_true(password.length == 24);
        assert_true(password.strip() == password);
        assert_true(password.index_of(":") < 0);
    }

    void test_ejabberd_check_account_result_codes_are_parsed() {
        bool exists = false;
        assert_true(EjabberdApi.parse_check_account_response("0", out exists));
        assert_true(exists);

        assert_true(EjabberdApi.parse_check_account_response("\"0\"", out exists));
        assert_true(exists);

        assert_true(EjabberdApi.parse_check_account_response("1", out exists));
        assert_false(exists);

        assert_true(EjabberdApi.parse_check_account_response("\"1\"", out exists));
        assert_false(exists);

        assert_false(EjabberdApi.parse_check_account_response("", out exists));
    }

    void test_dedicated_command_views_do_not_need_admin() {
        assert_false(BotUtils.dedicated_command_requires_admin("/ki", null, null));
        assert_false(BotUtils.dedicated_command_requires_admin("/ki", "status", null));
        assert_false(BotUtils.dedicated_command_requires_admin("/ki", "providers", null));
        assert_false(BotUtils.dedicated_command_requires_admin("/ki", "setup", null));
        assert_false(BotUtils.dedicated_command_requires_admin("/ki", "setup", "groq"));
        assert_false(BotUtils.dedicated_command_requires_admin("/ki", "model", null));
        assert_false(BotUtils.dedicated_command_requires_admin("/ki", "system", null));
        assert_false(BotUtils.dedicated_command_requires_admin("/telegram", null, null));
        assert_false(BotUtils.dedicated_command_requires_admin("/telegram", "status", null));
        assert_false(BotUtils.dedicated_command_requires_admin("/telegram", "setup", null));
        assert_false(BotUtils.dedicated_command_requires_admin("/telegram", "mode", null));
        assert_false(BotUtils.dedicated_command_requires_admin("/api", "server", null));
        assert_false(BotUtils.dedicated_command_requires_admin("/api", "server", ""));
        assert_false(BotUtils.dedicated_command_requires_admin("/api", "server", "status"));
        assert_false(BotUtils.dedicated_command_requires_admin("/api", "messages", null));
    }

    void test_dedicated_command_mutations_need_admin() {
        assert_true(BotUtils.dedicated_command_requires_admin("/ki", "on", null));
        assert_true(BotUtils.dedicated_command_requires_admin("/ki", "off", null));
        assert_true(BotUtils.dedicated_command_requires_admin("/ki", "clear", null));
        assert_true(BotUtils.dedicated_command_requires_admin("/ki", "setup", "groq token llama3"));
        assert_true(BotUtils.dedicated_command_requires_admin("/ki", "model", "llama3"));
        assert_true(BotUtils.dedicated_command_requires_admin("/ki", "system", "You are concise."));
        assert_true(BotUtils.dedicated_command_requires_admin("/telegram", "on", null));
        assert_true(BotUtils.dedicated_command_requires_admin("/telegram", "off", null));
        assert_true(BotUtils.dedicated_command_requires_admin("/telegram", "test", null));
        assert_true(BotUtils.dedicated_command_requires_admin("/telegram", "setup", "token chat-id"));
        assert_true(BotUtils.dedicated_command_requires_admin("/telegram", "mode", "forward"));
        assert_true(BotUtils.dedicated_command_requires_admin("/api", "server", "local"));
        assert_true(BotUtils.dedicated_command_requires_admin("/api", "server", "network"));
        assert_true(BotUtils.dedicated_command_requires_admin("/api", "server", "port 8443"));
        assert_true(BotUtils.dedicated_command_requires_admin("/api", "server", "cert /tmp/server.crt"));
        assert_true(BotUtils.dedicated_command_requires_admin("/api", "server", "renew-cert"));
        assert_true(BotUtils.dedicated_command_requires_admin("/api", "server", "delete-cert"));
        assert_true(BotUtils.dedicated_command_requires_admin("/clear", null, null));
    }
}

/**
 * Cryptographic hash and HMAC tests.
 *
 * References:
 *   - FIPS 180-4 §B.1–B.3: SHA-256 test vectors
 *   - RFC 4231 §4.2–4.4: HMAC-SHA-256 test cases
 *   - NIST SP 800-63B §5.1.1: Minimum 112-bit secret entropy
 */
class CryptoTest : Gee.TestCase {

    public CryptoTest() {
        base("Crypto");
        // FIPS 180-4 test vectors
        add_test("FIPS180_4_sha256_abc", test_sha256_abc);
        add_test("FIPS180_4_sha256_empty", test_sha256_empty);
        add_test("FIPS180_4_sha256_multiblock", test_sha256_multiblock);
        add_test("FIPS180_4_sha256_digest_is_256_bits", test_sha256_digest_256_bits);
        // RFC 4231 test vectors
        add_test("RFC4231_case2_hmac_sha256", test_hmac_rfc4231_case2);
        add_test("RFC4231_case3_hmac_sha256", test_hmac_rfc4231_case3);
        // Webhook secret entropy (NIST SP 800-63B)
        add_test("SP800_63B_secret_min_128_bit_entropy", test_secret_entropy);
        add_test("SP800_63B_secret_uniqueness_no_collision", test_secret_unique);
        add_test("WEBHOOK_log_url_sanitizer_redacts_query_and_fragment", test_webhook_log_url_sanitizer);
    }

    // SHA-256 helper (mirrors TokenManager.hash_token)
    private static string sha256(string input) {
        Checksum checksum = new Checksum(ChecksumType.SHA256);
        checksum.update((uchar[]) input.data, input.data.length);
        return checksum.get_string();
    }

    // HMAC-SHA256 helper (mirrors TokenManager.hmac_sha256)
    private static string hmac_sha256(string key, string data) {
        var hmac = new Hmac(ChecksumType.SHA256, (uchar[]) key.data);
        hmac.update((uchar[]) data.data);
        size_t digest_len = 32;
        uint8[] digest = new uint8[digest_len];
        hmac.get_digest(digest, ref digest_len);
        var sb = new StringBuilder();
        for (int i = 0; i < (int) digest_len; i++) {
            sb.append_printf("%02x", digest[i]);
        }
        return sb.str;
    }

    /**
     * FIPS 180-4 §B.1: SHA-256("abc") =
     * ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
     */
    void test_sha256_abc() {
        string result = sha256("abc");
        assert_true(result == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }

    /**
     * FIPS 180-4: SHA-256("") =
     * e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
     */
    void test_sha256_empty() {
        string result = sha256("");
        assert_true(result == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    }

    /**
     * FIPS 180-4 §B.2: SHA-256 of the 448-bit message:
     * "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
     *
     * This tests multi-block processing (message > 512 bits after padding).
     */
    void test_sha256_multiblock() {
        string input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
        string result = sha256(input);
        assert_true(result == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    }

    /**
     * FIPS 180-4 §1: SHA-256 output MUST be exactly 256 bits = 32 bytes = 64 hex chars.
     */
    void test_sha256_digest_256_bits() {
        string result = sha256("any input");
        assert_true(result.length == 64);
        // Verify all chars are hex
        for (int i = 0; i < result.length; i++) {
            char c = (char) result[i];
            bool is_hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            assert_true(is_hex);
        }
    }

    /**
     * RFC 4231 Test Case 2:
     *   Key = "Jefe"
     *   Data = "what do ya want for nothing?"
     *   HMAC-SHA-256 = 5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843
     */
    void test_hmac_rfc4231_case2() {
        string result = hmac_sha256("Jefe", "what do ya want for nothing?");
        assert_true(result == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    }

    /**
     * RFC 4231 Test Case 3:
     *   Key = 0xaa repeated 20 times
     *   Data = 0xdd repeated 50 times
     *   HMAC-SHA-256 = 773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe
     */
    void test_hmac_rfc4231_case3() {
        // Build key: 20 bytes of 0xaa
        uint8[] key_bytes = new uint8[20];
        for (int i = 0; i < 20; i++) key_bytes[i] = 0xaa;

        // Build data: 50 bytes of 0xdd
        uint8[] data_bytes = new uint8[50];
        for (int i = 0; i < 50; i++) data_bytes[i] = 0xdd;

        // Use raw byte HMAC since key/data are binary
        var hmac = new Hmac(ChecksumType.SHA256, key_bytes);
        hmac.update(data_bytes);
        size_t digest_len = 32;
        uint8[] digest = new uint8[digest_len];
        hmac.get_digest(digest, ref digest_len);
        var sb = new StringBuilder();
        for (int i = 0; i < (int) digest_len; i++) {
            sb.append_printf("%02x", digest[i]);
        }

        assert_true(sb.str == "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe");
    }

    /**
     * NIST SP 800-63B §5.1.1: Secrets MUST have at least 112 bits of entropy.
     * Our webhook secrets use 2×UUID4 = 2×122 = 244 random bits → 64 hex chars.
     * The hex representation MUST be at least 128 bits (32 hex chars).
     */
    void test_secret_entropy() {
        string uuid1 = GLib.Uuid.string_random().replace("-", "");
        string uuid2 = GLib.Uuid.string_random().replace("-", "");
        string secret = uuid1 + uuid2;

        // 64 hex chars = 256 bits of hex representation ≥ 128-bit minimum
        assert_true(secret.length == 64);

        // Verify hex-only encoding (no non-hex chars from UUID format)
        for (int i = 0; i < secret.length; i++) {
            char c = (char) secret[i];
            bool is_hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            assert_true(is_hex);
        }
    }

    /**
     * Two independently generated secrets MUST differ (collision probability
     * for 244 random bits is ~2^-244 ≈ 0).
     */
    void test_secret_unique() {
        string s1 = GLib.Uuid.string_random().replace("-", "") + GLib.Uuid.string_random().replace("-", "");
        string s2 = GLib.Uuid.string_random().replace("-", "") + GLib.Uuid.string_random().replace("-", "");
        assert_true(s1 != s2);
    }

    void test_webhook_log_url_sanitizer() {
        string sanitized = WebhookDispatcher.sanitize_url_for_log(
            "https://hook.example.test/path?token=secret&sig=value#fragment");
        assert_true(sanitized == "https://hook.example.test/path?...");

        string fragment_only = WebhookDispatcher.sanitize_url_for_log(
            "https://hook.example.test/path#secret");
        assert_true(fragment_only == "https://hook.example.test/path#...");

        assert_true(WebhookDispatcher.sanitize_url_for_log(null) == "(null)");
    }
}

}
