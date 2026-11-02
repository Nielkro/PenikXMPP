/**
 * Security audit tests for GPGHelper.parse_keylist_output().
 *
 * Tests the colon-format parser extracted from get_keylist().
 * No GPG binary needed — pure string → List<Key> transformation.
 *
 * Reference: GnuPG doc/DETAILS, --with-colons format
 *   Record types: pub, sec, fpr, uid, ssb, sub
 *   Field 2: validity (o, q, n, m, f, u, r, e, d)
 *   Field 10: user ID / fingerprint
 */

using Gee;
using GPGHelper;

namespace OpenPgp.Test {

class GPGKeylistParserTest : Gee.TestCase {

    private void test_windows_path_locale() {
        string? previous = Intl.setlocale(LocaleCategory.CTYPE, null);
        assert_true(Intl.setlocale(LocaleCategory.CTYPE, "") != null);
        try {
            assert_true(GPGHelper.to_windows_path("/i/İstanbul/日本語/العربية/gpg.exe") ==
                "I:\\İstanbul\\日本語\\العربية\\gpg.exe");
            assert_true(GPGHelper.to_windows_path("I:/İstanbul/gpg.exe") == "I:\\İstanbul\\gpg.exe");
            assert_true(GPGHelper.to_windows_path("//server/日本語/gpg.exe") == "\\\\server\\日本語\\gpg.exe");
        } finally { Intl.setlocale(LocaleCategory.CTYPE, previous); }
    }

    public GPGKeylistParserTest() {
        base("GPGKeylistParser");
        add_test("LOCALE_windows_paths_preserve_drive_and_unicode", test_windows_path_locale);

        /* Basic parsing */
        add_test("GPG_keylist_empty_output", test_empty_output);
        add_test("GPG_keylist_single_pub_key", test_single_pub_key);
        add_test("GPG_keylist_secret_key", test_secret_key);
        add_test("GPG_keylist_expired_key", test_expired_key);
        add_test("GPG_keylist_revoked_key", test_revoked_key);

        /* Email extraction */
        add_test("GPG_keylist_email_extraction", test_email_extraction);
        add_test("GPG_keylist_uid_no_email", test_uid_no_email);
        add_test("GPG_keylist_uid_malformed_brackets", test_uid_malformed_brackets);

        /* Fingerprint / key ID */
        add_test("GPG_keylist_keyid_from_fpr", test_keyid_from_fpr);
        add_test("GPG_keylist_short_fingerprint", test_short_fingerprint);

        /* Subkeys */
        add_test("GPG_keylist_subkey_fpr_skipped", test_subkey_fpr_skipped);
        add_test("GPG_decrypt_key_match_secret_primary", test_decrypt_key_match_secret_primary);
        add_test("GPG_decrypt_key_match_secret_subkey", test_decrypt_key_match_secret_subkey);
        add_test("GPG_decrypt_key_no_match", test_decrypt_key_no_match);
        add_test("GPG_plaintext_filename_strip_cr", test_plaintext_filename_strip_cr);
        add_test("GPG_plaintext_filename_unescape", test_plaintext_filename_unescape);
        add_test("GPG_decrypt_status_validsig_fingerprint", test_decrypt_status_validsig_fingerprint);
        add_test("GPG_decrypt_status_validsig_subkey_primary_fingerprint", test_decrypt_status_validsig_subkey_primary_fingerprint);
        add_test("GPG_decrypt_status_rejects_goodsig_without_validsig", test_decrypt_status_rejects_goodsig_without_validsig);
        add_test("GPG_import_status_fingerprints", test_import_status_fingerprints);
        add_test("OpenPGP_xep0374_fingerprint_match", test_xep0374_fingerprint_match);
        add_test("GPG_json_escape_for_vks_upload", test_json_escape_for_vks_upload);
        add_test("GPG_json_escape_UTF8_roundtrip", test_json_escape_utf8_roundtrip);
        add_test("GPG_json_escape_RFC8259_controls_roundtrip", test_json_escape_controls_roundtrip);
        add_test("GPG_json_escape_invalid_UTF8_roundtrip", test_json_escape_invalid_utf8_roundtrip);
        add_test("GPG_json_get_string_field", test_json_get_string_field);
        add_test("GPG_json_collect_email_keys", test_json_collect_email_keys);
        add_test("GPG_email_from_uid", test_email_from_uid);
        add_test("GPG_xmpp_uid_decoding_and_matching", test_xmpp_uid_decoding_and_matching);
        add_test("GPG_secret_key_batch_xmpp_uid", test_secret_key_batch_xmpp_uid);
        add_test("GPG_secret_key_batch_legacy_email", test_secret_key_batch_legacy_email);
        add_test("GPG_parse_user_ids_for_key", test_parse_user_ids_for_key);
        add_test("GPG_database_xep0027_may_replace_non_0374_xep0373_source", test_database_xep0027_replaces_non_0374_xep0373_source);
        add_test("GPG_database_preserves_0374_capable_xep0373_source", test_database_preserves_0374_xep0373_source);
        add_test("GPG_database_xep0374_support_can_exist_without_contact_key", test_database_xep0374_support_can_exist_without_contact_key);
        add_test("GPG_database_clears_only_matching_xmpp_contact_key", test_database_clears_only_matching_xmpp_contact_key);
        add_test("GPG_database_contact_keys_are_per_account", test_database_contact_keys_are_per_account);
        add_test("GPG_database_migration_does_not_copy_global_contact_keys_to_multiple_accounts", test_database_migration_does_not_copy_global_contact_keys_to_multiple_accounts);
        add_test("GPG_database_account_scoped_legacy_presence_reset", test_database_account_scoped_legacy_presence_reset);
        add_test("GPG_database_account_key_mode_defaults_to_xmpp", test_database_account_key_mode_defaults_to_xmpp);
        add_test("GPG_database_account_key_mode_persists_legacy", test_database_account_key_mode_persists_legacy);
        add_test("GPG_database_account_key_slots_are_separate", test_database_account_key_slots_are_separate);
        add_test("GPG_database_runtime_getters_ignore_stale_flat_key_fallback", test_database_runtime_getters_ignore_stale_flat_key_fallback);
        add_test("GPG_database_legacy_presence_state_preserves_stored_key", test_database_legacy_presence_state_preserves_stored_key);
        add_test("GPG_database_legacy_presence_startup_reset_preserves_stored_key", test_database_legacy_presence_startup_reset_preserves_stored_key);
        add_test("GPG_database_legacy_presence_key_requires_active_legacy_mode", test_database_legacy_presence_key_requires_active_legacy_mode);
        add_test("GPG_database_xmpp_mode_suppresses_legacy_presence_key", test_database_xmpp_mode_suppresses_legacy_presence_key);
        add_test("GPG_database_pending_xmpp_retractions_persist_per_account", test_database_pending_xmpp_retractions_persist_per_account);
        add_test("OpenPGP_bounded_subprocess_success", test_bounded_subprocess_success);
        add_test("OpenPGP_bounded_subprocess_failure_exit", test_bounded_subprocess_failure_exit);
        add_test("OpenPGP_bounded_subprocess_timeout", test_bounded_subprocess_timeout);

        /* Multiple keys */
        add_test("GPG_keylist_multiple_keys", test_multiple_keys);

        /* Edge cases */
        add_test("GPG_keylist_no_uid_no_add", test_no_uid_no_add);
        add_test("GPG_keylist_no_fpr_no_add", test_no_fpr_no_add);
        add_test("GPG_keylist_malformed_lines", test_malformed_lines);
        add_test("GPG_keylist_only_first_uid", test_only_first_uid);
    }

    /* ===== Basic parsing ===== */

    private void test_empty_output() {
        var keys = GPGHelper.parse_keylist_output("");
        fail_if_not_eq_int(keys.size, 0,
            "GPG: empty output must produce empty key list");
    }

    private void test_single_pub_key() {
        string output = "pub:u:::::::::\nfpr:::::::::ABCDEF1234567890ABCDEF1234567890ABCDEF12:\nuid:::::::::Alice <alice@example.com>:\n";
        var keys = GPGHelper.parse_keylist_output(output);
        fail_if_not_eq_int(keys.size, 1, "GPG: single pub key must produce 1 key");
        fail_if(keys[0].secret, "GPG: pub key must not be marked secret");
        fail_if(keys[0].expired, "GPG: valid key must not be expired");
        fail_if(keys[0].revoked, "GPG: valid key must not be revoked");
    }

    private void test_secret_key() {
        string output = "sec:u:::::::::\nfpr:::::::::ABCDEF1234567890ABCDEF1234567890ABCDEF12:\nuid:::::::::Bob <bob@example.com>:\n";
        var keys = GPGHelper.parse_keylist_output(output);
        fail_if_not_eq_int(keys.size, 1, "GPG: single sec key must produce 1 key");
        fail_if_not(keys[0].secret, "GPG: sec key must be marked secret");
    }

    private void test_plaintext_filename_strip_cr() {
        string status = "[GNUPG:] PLAINTEXT 62 1760000000 photo.jpg\r\n[GNUPG:] PLAINTEXT_LENGTH 12\r\n";
        string filename = GPGHelper.parse_plaintext_filename_from_status(status);
        fail_if_not_eq_str(filename, "photo.jpg",
            "GPG PLAINTEXT filename parser must strip CRLF from status output");
    }

    private void test_plaintext_filename_unescape() {
        string status = "[GNUPG:] PLAINTEXT 62 1760000000 my%20photo.jpg\n";
        string filename = GPGHelper.parse_plaintext_filename_from_status(status);
        fail_if_not_eq_str(filename, "my photo.jpg",
            "GPG PLAINTEXT filename parser must decode escaped filenames");
    }

    private void test_decrypt_status_validsig_fingerprint() {
        string status = "[GNUPG:] GOODSIG ABCDEF1234567890 Alice\n[GNUPG:] VALIDSIG 1234567890ABCDEF1234567890ABCDEF12345678 2026-05-17 0 4 0 1 10 00 1234567890ABCDEF1234567890ABCDEF12345678\n";
        string? signer = GPGHelper.parse_valid_signature_fingerprint_from_status(status);
        fail_if_not_eq_str(signer, "1234567890ABCDEF1234567890ABCDEF12345678",
            "GPG decrypt status parser must prefer the full VALIDSIG fingerprint");
    }

    private void test_decrypt_status_validsig_subkey_primary_fingerprint() {
        string subkey_fpr = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        string primary_fpr = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
        string status = "[GNUPG:] GOODSIG AAAAAAAAAAAAAAAA Alice\n[GNUPG:] VALIDSIG " + subkey_fpr + " 2026-05-20 0 4 0 1 10 00 " + primary_fpr + "\n";
        string? signer = GPGHelper.parse_valid_signature_fingerprint_from_status(status);
        fail_if_not_eq_str(signer, primary_fpr,
            "GPG decrypt status parser must map a signing subkey to the owning primary fingerprint");
    }

    private void test_decrypt_status_rejects_goodsig_without_validsig() {
        string status = "[GNUPG:] GOODSIG ABCDEF1234567890 Alice\n[GNUPG:] DECRYPTION_OKAY\n";
        string? signer = GPGHelper.parse_valid_signature_fingerprint_from_status(status);
        fail_if(signer != null,
            "GPG decrypt status parser must reject GOODSIG without full VALIDSIG fingerprint");
    }

    private void test_import_status_fingerprints() {
        string status = "[GNUPG:] IMPORT_OK 0 1234567890ABCDEF1234567890ABCDEF12345678\n[GNUPG:] IMPORT_RES 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n";
        Gee.List<string> fingerprints = GPGHelper.parse_imported_fingerprints_from_status(status);
        fail_if_not_eq_int(fingerprints.size, 1,
            "GPG import status parser must collect imported fingerprints");
        fail_if_not_eq_str(fingerprints[0], "1234567890ABCDEF1234567890ABCDEF12345678",
            "GPG import status parser must keep the imported fingerprint");
    }

    private void test_xep0374_fingerprint_match() {
        fail_if_not(Dino.Plugins.OpenPgp.ReceivedPipelineDecryptListener.fingerprint_or_keyid_matches(
                "1234 5678 90AB CDEF 1234 5678 90AB CDEF 1234 5678", "90ABCDEF12345678"),
            "XEP-0374 signer validation must allow key-ID suffix matches");
        fail_if(Dino.Plugins.OpenPgp.ReceivedPipelineDecryptListener.fingerprint_or_keyid_matches(
                "1234567890ABCDEF1234567890ABCDEF12345678", "1111111111111111"),
            "XEP-0374 signer validation must reject a different signer key");
    }

    private void test_json_escape_for_vks_upload() {
        string escaped = GPGHelper.json_escape("line1\n\"quoted\"\\path");
        fail_if_not_eq_str(escaped, "line1\\n\\\"quoted\\\"\\\\path",
            "GPG VKS JSON escaping must preserve key armor safely");
    }

    private string parse_escaped_json_value(string escaped) {
        try {
            var parser = new Json.Parser();
            parser.load_from_data("{\"value\":\"%s\"}".printf(escaped), -1);
            return parser.get_root().get_object().get_string_member("value");
        } catch (Error e) {
            GLib.Test.message("GPG escaped JSON did not parse: %s", e.message);
            GLib.Test.fail();
            return "";
        }
    }

    private void test_json_escape_utf8_roundtrip() {
        string input = "Ключ Игорь äöü 漢字 😀";
        string escaped = GPGHelper.json_escape(input);

        fail_if_not_eq_str(escaped, input,
            "GPG VKS JSON escaping must preserve valid UTF-8 codepoints");
        fail_if_not_eq_str(parse_escaped_json_value(escaped), input,
            "GPG VKS JSON must roundtrip Cyrillic, umlauts, CJK, and emoji");
    }

    private void test_json_escape_controls_roundtrip() {
        string c0 = ((unichar) 0x01).to_string();
        string input = "quote:\" slash:\\ backspace:\b formfeed:\f line:\n return:\r tab:\t c0:" + c0;
        string expected = "quote:\\\" slash:\\\\ backspace:\\b formfeed:\\f line:\\n return:\\r tab:\\t c0:\\u0001";
        string escaped = GPGHelper.json_escape(input);

        fail_if_not_eq_str(escaped, expected,
            "GPG VKS JSON escaping must retain RFC 8259 control escapes");
        fail_if_not_eq_str(parse_escaped_json_value(escaped), input,
            "GPG VKS JSON controls must parse back to the original value");
    }

    private void test_json_escape_invalid_utf8_roundtrip() {
        uint8[] bytes = { 'A', 0xff, 'B', 0 };
        string invalid = (string) bytes;
        string replacement = ((unichar) 0xfffd).to_string();
        fail_if(invalid.validate(), "GPG invalid-UTF8 fixture must be invalid before escaping");

        string escaped = GPGHelper.json_escape(invalid);
        fail_if_not(escaped.validate(), "GPG VKS escaped output must always be valid UTF-8");
        fail_if_not_eq_str(escaped, "A" + replacement + "B",
            "GPG VKS JSON escaping must replace invalid UTF-8 with U+FFFD");
        fail_if_not_eq_str(parse_escaped_json_value(escaped), "A" + replacement + "B",
            "GPG replacement-character JSON must remain parseable");
    }

    private void test_json_get_string_field() {
        string? token = GPGHelper.json_get_string_field("{\"token\":\"abc\\ndef\",\"status\":\"ok\"}", "token");
        fail_if_not_eq_str(token, "abc\ndef",
            "GPG VKS JSON parser must extract escaped token strings");
    }

    private void test_json_collect_email_keys() {
        Gee.List<string> emails = GPGHelper.json_collect_email_keys("{\"token\":\"t\",\"status\":{\"alice@example.com\":\"unpublished\",\"bob@example.com\":\"published\"}}");
        fail_if_not_eq_int(emails.size, 2,
            "GPG VKS JSON parser must collect email status keys");
        fail_if(!emails.contains("alice@example.com"),
            "GPG VKS JSON parser must collect first email address");
        fail_if(!emails.contains("bob@example.com"),
            "GPG VKS JSON parser must collect second email address");
    }

    private void test_email_from_uid() {
        fail_if_not_eq_str(GPGHelper.email_from_uid("Alice <alice@example.com>"), "alice@example.com",
            "GPG UID email parser must extract bracketed email");
        fail_if_not_eq_str(GPGHelper.email_from_uid("bob@example.com"), "bob@example.com",
            "GPG UID email parser must accept bare email");
        fail_if_not_eq_str(GPGHelper.email_from_uid("Alice (alice@example.com)"), "alice@example.com",
            "GPG UID email parser must extract parenthesized email");
        fail_if_not_eq_str(GPGHelper.email_from_uid("Alice <alice@example.com> (fallback)"), "alice@example.com",
            "GPG UID email parser must extract bracketed email before suffix text");
        fail_if_not_eq_str(GPGHelper.email_from_uid("  alice@example.com  "), "alice@example.com",
            "GPG UID email parser must trim whitespace around bare email");
        fail_if_not_eq_str(GPGHelper.email_from_uid("alice@localhost"), "alice@localhost",
            "GPG UID email parser must accept addresses without a dot in domain");
        fail_if(GPGHelper.email_from_uid("xmpp\\x3aalice@example.test") != null,
            "GPG UID email parser must not treat XMPP URI user IDs as email identities");
        fail_if(GPGHelper.email_from_uid("Alice <xmpp:alice@example.test>") != null,
            "GPG UID email parser must not treat XMPP UID values inside angle brackets as email identities");
        fail_if(GPGHelper.email_from_uid("mailto:alice@example.com") != null,
            "GPG UID email parser must not treat mailto: URIs as email identities");
    }

    private void test_xmpp_uid_decoding_and_matching() {
        fail_if_not_eq_str(GPGHelper.decode_gpg_colon_escapes("xmpp\\x3aalice@example.test"), "xmpp:alice@example.test",
            "GPG colon parser must decode escaped colons in XMPP user IDs");
        fail_if_not(GPGHelper.uid_matches_xmpp_jid("xmpp\\x3aalice@example.test", "alice@example.test"),
            "GPG XMPP UID matcher must accept escaped xmpp:bare-jid");
        fail_if(GPGHelper.uid_matches_xmpp_jid("xmpp\\x3amallory@example.test", "alice@example.test"),
            "GPG XMPP UID matcher must reject a different bare JID");
    }

    private void test_secret_key_batch_xmpp_uid() {
        string batch = GPGHelper.build_secret_key_batch("Alice", "alice@example.test", "", GPGHelper.SecretKeyUserIdMode.XMPP);
        fail_if_not(batch.contains("Name-Real: xmpp:alice@example.test\n"),
            "GPG XMPP key generation must create an xmpp:bare-jid user ID");
        fail_if(batch.contains("Name-Email:"),
            "GPG XMPP key generation must not create a normal email user ID");
    }

    private void test_secret_key_batch_legacy_email() {
        string batch = GPGHelper.build_secret_key_batch("Alice", "alice@example.test", "", GPGHelper.SecretKeyUserIdMode.EMAIL);
        fail_if_not(batch.contains("Name-Real: Alice\n"),
            "GPG legacy key generation must keep the display name");
        fail_if_not(batch.contains("Name-Email: alice@example.test\n"),
            "GPG legacy key generation must keep the real email address for keyserver verification");
        fail_if(batch.contains("Name-Real: xmpp:"),
            "GPG legacy key generation must not create an XMPP URI user ID");
    }

    private void test_bounded_subprocess_success() {
        string? true_path = Environment.find_program_in_path("true");
        if (true_path == null) {
            GLib.Test.skip("true executable not available for bounded subprocess proof");
            return;
        }

        int exit_status;
        string stderr_str;
        bool ok = Dino.Plugins.OpenPgp.run_bounded_subprocess(
            { (!) true_path }, "", 1, out exit_status, out stderr_str,
            "bounded subprocess success test");
        fail_if_not(ok, "OpenPGP bounded subprocess helper must report true(1) success");
        fail_if_not_eq_int(exit_status, 0, "OpenPGP bounded subprocess helper must keep the success exit status");
    }

    private void test_bounded_subprocess_failure_exit() {
        string? false_path = Environment.find_program_in_path("false");
        if (false_path == null) {
            GLib.Test.skip("false executable not available for bounded subprocess proof");
            return;
        }

        int exit_status;
        string stderr_str;
        bool ok = Dino.Plugins.OpenPgp.run_bounded_subprocess(
            { (!) false_path }, "", 1, out exit_status, out stderr_str,
            "bounded subprocess failure test");
        fail_if(ok, "OpenPGP bounded subprocess helper must report non-zero exit as failure");
        fail_if_not_eq_int(exit_status, 1, "OpenPGP bounded subprocess helper must keep the non-zero exit status");
        fail_if(stderr_str.contains("timed out"),
            "OpenPGP bounded subprocess helper must not report normal non-zero exit as timeout");
    }

    private void test_bounded_subprocess_timeout() {
        string? sleep_path = Environment.find_program_in_path("sleep");
        if (sleep_path == null) {
            GLib.Test.skip("sleep executable not available for bounded subprocess timeout proof");
            return;
        }

        int exit_status;
        string stderr_str;
        int64 start = get_monotonic_time();
        bool ok = Dino.Plugins.OpenPgp.run_bounded_subprocess(
            { (!) sleep_path, "10" }, "", 1, out exit_status, out stderr_str,
            "bounded subprocess timeout test");
        int64 elapsed_us = get_monotonic_time() - start;

        fail_if(ok, "OpenPGP bounded subprocess helper must report timeout as failure");
        fail_if_not_eq_int(exit_status, -2, "OpenPGP bounded subprocess helper must mark timed-out commands with -2");
        fail_if(!stderr_str.contains("timed out"),
            "OpenPGP bounded subprocess helper must expose a timeout diagnostic");
        fail_if(elapsed_us > 3000000,
            "OpenPGP bounded subprocess helper must terminate and reap the timed-out child");
    }

    private void test_parse_user_ids_for_key() {
        string fpr = "ABCDEF1234567890ABCDEF1234567890ABCDEF12";
        string output = "pub:u:::::::::\nfpr:::::::::" + fpr + ":\nuid:::::::::xmpp\\x3aalice@example.test:\nsub:u:::::::::\nfpr:::::::::1111111111111111111111111111111111111111:\n";
        Gee.List<string> uids = GPGHelper.parse_user_ids_for_key(output, fpr);
        fail_if_not_eq_int(uids.size, 1,
            "GPG user ID parser must collect primary-key UIDs for the matched fingerprint");
        fail_if_not_eq_str(uids[0], "xmpp:alice@example.test",
            "GPG user ID parser must decode XMPP URI user IDs");
    }

    private Dino.Entities.Account make_test_account(string jid, int id) throws Error {
        var account = new Dino.Entities.Account(new Xmpp.Jid(jid), "secret");
        account.id = id;
        return account;
    }

    private void create_legacy_openpgp_db_with_global_contact_key(string db_path, bool multiple_accounts) throws Error {
        var setup_db = new Dino.Plugins.OpenPgp.Database(db_path, null);
        setup_db.exec("DROP TABLE contact_key");
        setup_db.exec("DELETE FROM account_setting");
        setup_db.exec("UPDATE _meta SET int_val = 9 WHERE name = 'version'");
        setup_db.exec("CREATE TABLE contact_key (jid TEXT PRIMARY KEY, key TEXT NOT NULL, source TEXT DEFAULT 'unknown', supports_xep0374 INTEGER DEFAULT 0, legacy_key TEXT, xmpp_key TEXT, legacy_announced INTEGER DEFAULT 0)");
        setup_db.exec("INSERT INTO account_setting (account_id, key, key_mode, xmpp_key) VALUES (11, 'ACCOUNT1', 'xmpp', 'ACCOUNT1')");
        if (multiple_accounts) {
            setup_db.exec("INSERT INTO account_setting (account_id, key, key_mode, xmpp_key) VALUES (12, 'ACCOUNT2', 'xmpp', 'ACCOUNT2')");
        }
        setup_db.exec("INSERT INTO contact_key (jid, key, source, supports_xep0374, legacy_key, xmpp_key, legacy_announced) VALUES ('same-contact@example.test', 'GLOBAL_XMPP', 'xep0373', 1, 'GLOBAL_LEGACY', 'GLOBAL_XMPP', 1)");
        setup_db.close();
    }

    private void test_database_xep0027_replaces_non_0374_xep0373_source() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
            var account = make_test_account("account@example.test", 1);
            Xmpp.Jid jid = new Xmpp.Jid("legacy@example.com");
            db.set_contact_key(account, jid, "XEP0373KEY", Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, false);
            db.set_contact_key(account, jid, "XEP0027KEY", Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false);
            fail_if_not_eq_str(db.get_contact_legacy_key(account, jid), "XEP0027KEY",
                "OpenPGP DB must store the XEP-0027 key as legacy key");
            fail_if_not_eq_str(db.get_contact_xmpp_key(account, jid), "XEP0373KEY",
                "OpenPGP DB must keep the XEP-0373 key separate from the legacy key");
            fail_if_not_eq_str(db.get_contact_key_for_mode(account, jid, Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_LEGACY), "XEP0027KEY",
                "Legacy mode must select the XEP-0027 key");
            fail_if_not_eq_str(db.get_contact_key_for_mode(account, jid, Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_XMPP), "XEP0373KEY",
                "XMPP mode must select the XEP-0373 key");
        } catch (Error e) {
            GLib.Test.message("OpenPGP DB test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_database_preserves_0374_xep0373_source() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
            var account = make_test_account("account@example.test", 1);
            Xmpp.Jid jid = new Xmpp.Jid("modern@example.com");
            db.set_contact_key(account, jid, "XEP0373KEY", Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
            db.set_contact_key(account, jid, "XEP0027KEY", Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false);
            fail_if_not_eq_str(db.get_contact_legacy_key(account, jid), "XEP0027KEY",
                "OpenPGP DB must store the legacy key independently");
            fail_if_not_eq_str(db.get_contact_xmpp_key(account, jid), "XEP0373KEY",
                "OpenPGP DB must preserve the XEP-0373 key independently");
            fail_if_not_eq_str(db.get_contact_key_for_mode(account, jid, Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_LEGACY), "XEP0027KEY",
                "Legacy mode must select the legacy key");
            fail_if_not_eq_str(db.get_contact_key_for_mode(account, jid, Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_XMPP), "XEP0373KEY",
                "XMPP mode must select the XMPP key");
            db.clear_contact_xmpp_key(account, jid);
            fail_if_not(db.get_contact_xmpp_key(account, jid) == null,
                "Clearing the XMPP key must not fall back to the legacy contact_key field");
            fail_if_not_eq_str(db.get_contact_key_for_mode(account, jid, Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_LEGACY), "XEP0027KEY",
                "Clearing the XMPP key must not remove the legacy key");
            fail_if_not(db.contact_supports_xep0374(account, jid),
                "OpenPGP DB must preserve XEP-0374 support flag");
        } catch (Error e) {
            GLib.Test.message("OpenPGP DB test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_database_xep0374_support_can_exist_without_contact_key() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
            var account = make_test_account("account@example.test", 1);
            Xmpp.Jid jid = new Xmpp.Jid("xmpp-only@example.test");

            db.set_contact_supports_xep0374(account, jid, true);
            fail_if(!db.contact_supports_xep0374(account, jid),
                "OpenPGP DB must persist XEP-0374 support even before a contact key is stored");
            fail_if_not(db.get_contact_xmpp_key(account, jid) == null,
                "Support-only state must not invent an XMPP contact key");
            fail_if_not(db.get_contact_legacy_key(account, jid) == null,
                "Support-only state must not invent a legacy contact key");

            db.set_contact_key(account, jid, "XMPPKEY", Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, false);
            fail_if_not_eq_str(db.get_contact_xmpp_key(account, jid), "XMPPKEY",
                "Adding an XEP-0373 key later must still store the XMPP key");
            fail_if(!db.contact_supports_xep0374(account, jid),
                "Adding an XEP-0373 key must preserve the support flag");
        } catch (Error e) {
            GLib.Test.message("OpenPGP DB support-only test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_database_clears_only_matching_xmpp_contact_key() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
            var account = make_test_account("account@example.test", 1);
            Xmpp.Jid jid = new Xmpp.Jid("contact@example.test");
            db.set_contact_key(account, jid, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
            db.set_contact_key(account, jid, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false);

            fail_if(db.clear_contact_xmpp_key_if_matches(account, jid, "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"),
                "OpenPGP DB must not clear a different stored XMPP contact key");
            fail_if_not_eq_str(db.get_contact_xmpp_key(account, jid), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "OpenPGP DB must keep the stored XMPP key when the rejected fingerprint differs");
            fail_if_not_eq_str(db.get_contact_legacy_key(account, jid), "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                "OpenPGP DB must never clear the legacy key when rejecting an XMPP key");

            fail_if(!db.clear_contact_xmpp_key_if_matches(account, jid, "AAAAAAAAAAAAAAAA"),
                "OpenPGP DB must clear the stored XMPP key when the rejected key ID matches");
            fail_if_not(db.get_contact_xmpp_key(account, jid) == null,
                "OpenPGP DB must remove the matching XMPP key");
            fail_if_not_eq_str(db.get_contact_legacy_key(account, jid), "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                "OpenPGP DB must preserve the legacy key after clearing the XMPP key");
        } catch (Error e) {
            GLib.Test.message("OpenPGP DB conditional XMPP clear test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_database_contact_keys_are_per_account() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
            var account1 = make_test_account("one@example.test", 11);
            var account2 = make_test_account("two@example.test", 12);
            Xmpp.Jid jid = new Xmpp.Jid("same-contact@example.test");

            db.set_contact_key(account1, jid, "ACCOUNT1_XMPP", Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, true);
            db.set_contact_key(account1, jid, "ACCOUNT1_LEGACY", Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false, true);
            db.set_contact_key(account2, jid, "ACCOUNT2_XMPP", Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373, false);
            db.set_contact_supports_xep0374(account2, jid, false);

            fail_if_not_eq_str(db.get_contact_xmpp_key(account1, jid), "ACCOUNT1_XMPP",
                "OpenPGP contact XMPP key must be stored per account");
            fail_if_not_eq_str(db.get_contact_legacy_key(account1, jid), "ACCOUNT1_LEGACY",
                "OpenPGP contact legacy key must be stored per account");
            fail_if(db.get_contact_legacy_key(account2, jid) != null,
                "OpenPGP contact legacy key must not leak to another account");
            fail_if_not_eq_str(db.get_contact_xmpp_key(account2, jid), "ACCOUNT2_XMPP",
                "OpenPGP contact XMPP key for another account must remain independent");
            fail_if(!db.contact_supports_xep0374(account1, jid),
                "OpenPGP XEP-0374 support flag must be stored per account");
            fail_if(db.contact_supports_xep0374(account2, jid),
                "OpenPGP XEP-0374 support flag must not leak to another account");

            db.clear_contact_xmpp_key(account2, jid);
            fail_if_not_eq_str(db.get_contact_xmpp_key(account1, jid), "ACCOUNT1_XMPP",
                "Clearing one account's XMPP contact key must not affect another account");
            fail_if(db.get_contact_xmpp_key(account2, jid) != null,
                "Clearing one account's XMPP contact key must clear only that account");
        } catch (Error e) {
            GLib.Test.message("OpenPGP per-account contact key DB test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_database_migration_does_not_copy_global_contact_keys_to_multiple_accounts() {
        string single_db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-migrate-single-%u.db".printf(Random.next_int()));
        string multi_db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-migrate-multi-%u.db".printf(Random.next_int()));
        Xmpp.Jid jid;
        try {
            jid = new Xmpp.Jid("same-contact@example.test");
            var account1 = make_test_account("one@example.test", 11);
            var account2 = make_test_account("two@example.test", 12);

            create_legacy_openpgp_db_with_global_contact_key(single_db_path, false);
            var single_db = new Dino.Plugins.OpenPgp.Database(single_db_path, null);
            fail_if_not_eq_str(single_db.get_contact_xmpp_key(account1, jid), "GLOBAL_XMPP",
                "Single-account migration may preserve a formerly global XMPP contact key");
            fail_if_not_eq_str(single_db.get_contact_legacy_key(account1, jid), "GLOBAL_LEGACY",
                "Single-account migration may preserve a formerly global legacy contact key");
            fail_if(!single_db.contact_supports_xep0374(account1, jid),
                "Single-account migration must preserve XEP-0374 support state");
            fail_if(!single_db.contact_legacy_key_is_announced(account1, jid),
                "Single-account migration must preserve live legacy state for the only possible owner");
            single_db.close();

            create_legacy_openpgp_db_with_global_contact_key(multi_db_path, true);
            var multi_db = new Dino.Plugins.OpenPgp.Database(multi_db_path, null);
            fail_if(multi_db.get_contact_xmpp_key(account1, jid) != null,
                "Multi-account migration must not copy an unattributed global XMPP contact key to account 1");
            fail_if(multi_db.get_contact_legacy_key(account1, jid) != null,
                "Multi-account migration must not copy an unattributed global legacy contact key to account 1");
            fail_if(multi_db.contact_supports_xep0374(account1, jid),
                "Multi-account migration must not copy unattributed XEP-0374 support to account 1");
            fail_if(multi_db.contact_legacy_key_is_announced(account1, jid),
                "Multi-account migration must not copy unattributed live legacy state to account 1");
            fail_if(multi_db.get_contact_xmpp_key(account2, jid) != null,
                "Multi-account migration must not copy an unattributed global XMPP contact key to account 2");
            fail_if(multi_db.get_contact_legacy_key(account2, jid) != null,
                "Multi-account migration must not copy an unattributed global legacy contact key to account 2");
            multi_db.close();
        } catch (Error e) {
            GLib.Test.message("OpenPGP per-account migration test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(single_db_path);
            FileUtils.remove(single_db_path + "-wal");
            FileUtils.remove(single_db_path + "-shm");
            FileUtils.remove(multi_db_path);
            FileUtils.remove(multi_db_path + "-wal");
            FileUtils.remove(multi_db_path + "-shm");
        }
    }

    private void test_database_account_scoped_legacy_presence_reset() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
            var account1 = make_test_account("one@example.test", 11);
            var account2 = make_test_account("two@example.test", 12);
            Xmpp.Jid jid = new Xmpp.Jid("same-contact@example.test");

            db.set_contact_key(account1, jid, "ACCOUNT1_LEGACY", Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false, true);
            db.set_contact_key(account2, jid, "ACCOUNT2_LEGACY", Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false, true);

            db.clear_contact_legacy_key_announcements(account1);
            fail_if(db.contact_legacy_key_is_announced(account1, jid),
                "Account-scoped legacy reset must clear only the selected account");
            fail_if(!db.contact_legacy_key_is_announced(account2, jid),
                "Account-scoped legacy reset must not clear another account");
            fail_if_not_eq_str(db.get_contact_legacy_key(account1, jid), "ACCOUNT1_LEGACY",
                "Account-scoped legacy reset must preserve account 1's stored key");
            fail_if_not_eq_str(db.get_contact_legacy_key(account2, jid), "ACCOUNT2_LEGACY",
                "Account-scoped legacy reset must preserve account 2's stored key");
        } catch (Error e) {
            GLib.Test.message("OpenPGP account-scoped legacy reset DB test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_database_account_key_mode_defaults_to_xmpp() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
            var account = new Dino.Entities.Account(new Xmpp.Jid("alice@example.test"), "secret");
            account.id = 42;
            db.set_account_key(account, "XMPPKEY");
            fail_if_not_eq_str(db.get_account_key(account), "XMPPKEY",
                "OpenPGP DB must store the account key");
            fail_if_not_eq_str(db.get_account_key_mode(account), Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_XMPP,
                "OpenPGP DB must default account keys to XMPP mode");
        } catch (Error e) {
            GLib.Test.message("OpenPGP DB account mode test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_database_account_key_mode_persists_legacy() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
            var account = new Dino.Entities.Account(new Xmpp.Jid("bob@example.test"), "secret");
            account.id = 43;
            db.set_account_key(account, "LEGACYKEY", Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_LEGACY);
            fail_if_not_eq_str(db.get_account_key(account), "LEGACYKEY",
                "OpenPGP DB must store the legacy account key");
            fail_if_not_eq_str(db.get_account_key_mode(account), Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_LEGACY,
                "OpenPGP DB must persist legacy account key mode");
        } catch (Error e) {
            GLib.Test.message("OpenPGP DB account mode test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_database_account_key_slots_are_separate() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
            var account = new Dino.Entities.Account(new Xmpp.Jid("carol@example.test"), "secret");
            account.id = 44;

            db.set_account_xmpp_key(account, "XMPPKEY");
            fail_if_not_eq_str(db.get_account_xmpp_key(account), "XMPPKEY",
                "Selecting an XMPP account key must activate XMPP mode");
            fail_if_not(db.get_account_legacy_key(account) == null,
                "Selecting an XMPP account key with no legacy slot must not invent a legacy account key");

            db.set_account_legacy_key(account, "LEGACYKEY");

            fail_if_not_eq_str(db.get_account_xmpp_key(account), "XMPPKEY",
                "Selecting a legacy account key must preserve the XMPP account key for later switching");
            fail_if_not_eq_str(db.get_account_legacy_key(account), "LEGACYKEY",
                "Selecting a legacy account key must activate legacy mode");
            fail_if_not_eq_str(db.get_account_key_mode(account), Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_LEGACY,
                "Selecting a legacy account key must switch outgoing OpenPGP to legacy mode");
            fail_if_not_eq_str(db.get_account_key(account), "LEGACYKEY",
                "Mode-selected account key must use the active legacy slot");
            fail_if_not_eq_str(db.get_account_key_for_mode(account, Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_XMPP), "XMPPKEY",
                "XMPP mode lookup must keep the preserved XMPP key");
            fail_if_not_eq_str(db.get_account_key_for_mode(account, Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_LEGACY), "LEGACYKEY",
                "Legacy mode must select the legacy account key");

            db.set_account_xmpp_key(account, "XMPPKEY2");
            fail_if_not_eq_str(db.get_account_key_mode(account), Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_XMPP,
                "Selecting an XMPP account key must switch outgoing OpenPGP to XMPP mode");
            fail_if_not_eq_str(db.get_account_legacy_key(account), "LEGACYKEY",
                "Selecting an XMPP account key must preserve the legacy keyserver slot");

            db.remove_account_legacy_key(account);
            fail_if_not_eq_str(db.get_account_xmpp_key(account), "XMPPKEY2",
                "Removing the inactive legacy account key must preserve the XMPP account key");
            fail_if_not(db.get_account_legacy_key(account) == null,
                "Removing a legacy account key must leave legacy inactive");
            fail_if_not_eq_str(db.get_account_key_mode(account), Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_XMPP,
                "Removing an inactive legacy slot must keep XMPP mode active");

            db.set_account_legacy_key(account, "LEGACYKEY2");
            db.remove_account_xmpp_key(account);
            fail_if_not(db.get_account_xmpp_key(account) == null,
                "Removing an XMPP account key must leave XMPP inactive");
            fail_if_not_eq_str(db.get_account_legacy_key(account), "LEGACYKEY2",
                "Removing the inactive XMPP account key must preserve the legacy keyserver slot");
            fail_if_not_eq_str(db.get_account_key_mode(account), Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_LEGACY,
                "Removing an XMPP slot while legacy exists must make legacy the active mode");
        } catch (Error e) {
            GLib.Test.message("OpenPGP DB account key slot test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_database_runtime_getters_ignore_stale_flat_key_fallback() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
            var account = new Dino.Entities.Account(new Xmpp.Jid("dave@example.test"), "secret");
            account.id = 45;
            Xmpp.Jid jid = new Xmpp.Jid("contact@example.test");

            db.set_contact_key(account, jid, "LEGACYKEY", Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false);
            db.exec("UPDATE contact_key SET key = 'STALE_XMPP_KEY', source = 'xep0373', xmpp_key = NULL WHERE jid = 'contact@example.test'");
            fail_if_not(db.get_contact_xmpp_key(account, jid) == null,
                "Contact XMPP getter must not fall back to stale flat key/source state");
            fail_if_not_eq_str(db.get_contact_legacy_key(account, jid), "LEGACYKEY",
                "Contact legacy getter must keep the dedicated legacy key");

            db.set_account_legacy_key(account, "LEGACY_ACCOUNT_KEY");
            db.exec("UPDATE account_setting SET key = 'STALE_XMPP_ACCOUNT_KEY', key_mode = 'xmpp', xmpp_key = NULL WHERE account_id = 45");
            fail_if_not(db.get_account_xmpp_key(account) == null,
                "Account XMPP getter must not fall back to stale flat key state");
            fail_if_not(db.get_account_key(account) == null,
                "Mode-selected account key must not fall back to stale flat key state");
        } catch (Error e) {
            GLib.Test.message("OpenPGP DB stale fallback test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_database_xmpp_mode_suppresses_legacy_presence_key() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
            var account = new Dino.Entities.Account(new Xmpp.Jid("erin@example.test"), "secret");
            account.id = 46;

            db.set_account_legacy_key(account, "LEGACYKEY");
            fail_if_not_eq_str(db.get_account_key_mode(account), Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_LEGACY,
                "Selecting a legacy key must activate legacy mode");
            fail_if_not_eq_str(db.get_account_legacy_key_for_presence(account), "LEGACYKEY",
                "Legacy mode must announce the legacy key in signed presence");

            db.set_account_xmpp_key(account, "XMPPKEY");
            fail_if_not_eq_str(db.get_account_key_mode(account), Dino.Plugins.OpenPgp.Database.ACCOUNT_KEY_MODE_XMPP,
                "Selecting an XMPP key must activate XMPP mode");
            fail_if_not_eq_str(db.get_account_key(account), "XMPPKEY",
                "Mode-selected account key must be the XMPP key");
            fail_if_not(db.get_account_legacy_key_for_presence(account) == null,
                "XMPP mode must not announce the stored legacy key in signed presence");
            fail_if_not_eq_str(db.get_account_legacy_key(account), "LEGACYKEY",
                "XMPP mode must keep the legacy key stored for later switching");
        } catch (Error e) {
            GLib.Test.message("OpenPGP DB XMPP mode presence suppression test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_database_pending_xmpp_retractions_persist_per_account() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var account1 = new Dino.Entities.Account(new Xmpp.Jid("one@example.test"), "secret");
            account1.id = 47;
            var account2 = new Dino.Entities.Account(new Xmpp.Jid("two@example.test"), "secret");
            account2.id = 48;
            string fingerprint = "20A4BA7F26F9AC2DFC0638FE2EC7F2A5B886FCC2";

            {
                var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
                db.mark_pending_xmpp_key_retraction(account1, fingerprint);
                db.mark_pending_xmpp_key_retraction(account1, fingerprint.down());
                db.mark_pending_xmpp_key_retraction(account2, fingerprint);
            }

            var reopened = new Dino.Plugins.OpenPgp.Database(db_path, null);
            Gee.List<string> account1_retractions = reopened.get_pending_xmpp_key_retractions(account1);
            Gee.List<string> account2_retractions = reopened.get_pending_xmpp_key_retractions(account2);
            fail_if_not_eq_int(account1_retractions.size, 1,
                "OpenPGP DB must deduplicate pending XMPP retractions per account/fingerprint");
            fail_if_not_eq_str(account1_retractions[0], fingerprint,
                "OpenPGP DB must store pending XMPP retraction fingerprints in canonical form");
            fail_if_not_eq_int(account2_retractions.size, 1,
                "OpenPGP DB must store pending XMPP retractions separately per account");

            reopened.clear_pending_xmpp_key_retraction(account1, fingerprint);
            fail_if_not_eq_int(reopened.get_pending_xmpp_key_retractions(account1).size, 0,
                "OpenPGP DB must clear the matching pending XMPP retraction");
            fail_if_not_eq_int(reopened.get_pending_xmpp_key_retractions(account2).size, 1,
                "OpenPGP DB must not clear another account's pending XMPP retraction");
        } catch (Error e) {
            GLib.Test.message("OpenPGP pending XMPP retraction DB test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_database_legacy_presence_state_preserves_stored_key() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
            var account = make_test_account("legacy-owner@example.test", 1);
            Xmpp.Jid jid = new Xmpp.Jid("legacy-presence@example.test");

            db.set_contact_key(account, jid, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_KEYSERVER, false);
            fail_if(db.contact_legacy_key_is_announced(account, jid),
                "A manually/keyserver-stored legacy key must not be treated as currently announced");

            db.set_contact_key(account, jid, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false, true);
            fail_if(!db.contact_legacy_key_is_announced(account, jid),
                "A signed XEP-0027 presence must mark the stored legacy key as currently announced");

            db.set_contact_legacy_key_announced(account, jid, false);
            fail_if(db.contact_legacy_key_is_announced(account, jid),
                "Stopping XEP-0027 announcement must clear only the announcement state");
            fail_if_not_eq_str(db.get_contact_legacy_key(account, jid), "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                "Stopping XEP-0027 announcement must preserve the stored legacy contact key");
        } catch (Error e) {
            GLib.Test.message("OpenPGP DB legacy presence state test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_database_legacy_presence_startup_reset_preserves_stored_key() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
            var account = make_test_account("legacy-owner@example.test", 1);
            Xmpp.Jid jid = new Xmpp.Jid("legacy-reset@example.test");

            db.set_contact_key(account, jid, "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
                Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027, false, true);
            fail_if(!db.contact_legacy_key_is_announced(account, jid),
                "A signed XEP-0027 presence must mark the stored legacy key as currently announced");

            db.clear_contact_legacy_key_announcements();
            fail_if(db.contact_legacy_key_is_announced(account, jid),
                "Startup reset must clear live XEP-0027 announcement state");
            fail_if_not_eq_str(db.get_contact_legacy_key(account, jid), "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
                "Startup reset must preserve the stored legacy contact key");
        } catch (Error e) {
            GLib.Test.message("OpenPGP DB legacy presence startup reset test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_database_legacy_presence_key_requires_active_legacy_mode() {
        string db_path = Path.build_filename(Environment.get_tmp_dir(), "dinox-openpgp-test-%u.db".printf(Random.next_int()));
        try {
            var db = new Dino.Plugins.OpenPgp.Database(db_path, null);
            var account = new Dino.Entities.Account(new Xmpp.Jid("mode-switch@example.test"), "secret");
            account.id = 46;

            db.set_account_legacy_key(account, "LEGACYKEY");
            fail_if_not_eq_str(db.get_account_legacy_key_for_presence(account), "LEGACYKEY",
                "Legacy mode must announce the selected legacy key in XEP-0027 presence");

            db.set_account_xmpp_key(account, "XMPPKEY");
            fail_if_not(db.get_account_legacy_key(account) != null,
                "Switching to XMPP mode must preserve the stored legacy account key");
            fail_if_not(db.get_account_legacy_key_for_presence(account) == null,
                "XMPP mode must not announce a preserved legacy account key in XEP-0027 presence");

            db.remove_account_xmpp_key(account);
            fail_if_not_eq_str(db.get_account_legacy_key_for_presence(account), "LEGACYKEY",
                "Removing the XMPP key must restore legacy presence only when legacy becomes the active mode");
        } catch (Error e) {
            GLib.Test.message("OpenPGP DB legacy presence key mode test failed: %s", e.message);
            GLib.Test.fail();
        } finally {
            FileUtils.remove(db_path);
            FileUtils.remove(db_path + "-wal");
            FileUtils.remove(db_path + "-shm");
        }
    }

    private void test_expired_key() {
        string output = "pub:e:::::::::\nfpr:::::::::ABCDEF1234567890ABCDEF1234567890ABCDEF12:\nuid:::::::::Expired <exp@example.com>:\n";
        var keys = GPGHelper.parse_keylist_output(output);
        fail_if_not_eq_int(keys.size, 1, "GPG: expired key must be parsed");
        fail_if_not(keys[0].expired, "GPG: validity 'e' must set expired=true");
        fail_if(keys[0].revoked, "GPG: expired key must not be revoked");
    }

    private void test_revoked_key() {
        string output = "pub:r:::::::::\nfpr:::::::::ABCDEF1234567890ABCDEF1234567890ABCDEF12:\nuid:::::::::Revoked <rev@example.com>:\n";
        var keys = GPGHelper.parse_keylist_output(output);
        fail_if_not_eq_int(keys.size, 1, "GPG: revoked key must be parsed");
        fail_if_not(keys[0].revoked, "GPG: validity 'r' must set revoked=true");
        fail_if(keys[0].expired, "GPG: revoked key must not be expired");
    }

    /* ===== Email extraction ===== */

    private void test_email_extraction() {
        string output = "pub:u:::::::::\nfpr:::::::::ABCDEF1234567890ABCDEF1234567890ABCDEF12:\nuid:::::::::Alice Smith <alice@example.com>:\n";
        var keys = GPGHelper.parse_keylist_output(output);
        fail_if_not_eq_int(keys.size, 1, "GPG: key must be parsed");
        fail_if_not_eq_str(keys[0].email, "alice@example.com",
            "GPG: email must be extracted from <...> in uid");
        fail_if_not_eq_str(keys[0].uid, "Alice Smith <alice@example.com>",
            "GPG: full uid must be preserved");
    }

    private void test_uid_no_email() {
        string output = "pub:u:::::::::\nfpr:::::::::ABCDEF1234567890ABCDEF1234567890ABCDEF12:\nuid:::::::::Just A Name:\n";
        var keys = GPGHelper.parse_keylist_output(output);
        fail_if_not_eq_int(keys.size, 1, "GPG: key with no-email uid must be parsed");
        fail_if_not_eq_str(keys[0].uid, "Just A Name",
            "GPG: uid without email must be preserved");
        fail_if(keys[0].email != null,
            "GPG: uid without <...> must have null email");
    }

    private void test_uid_malformed_brackets() {
        // > before < — malformed
        string output = "pub:u:::::::::\nfpr:::::::::ABCDEF1234567890ABCDEF1234567890ABCDEF12:\nuid:::::::::Name >bad< stuff:\n";
        var keys = GPGHelper.parse_keylist_output(output);
        fail_if_not_eq_int(keys.size, 1, "GPG: key with malformed uid must be parsed");
        // The parser does index_of("<") and index_of(">") separately
        // With ">bad<", index_of("<") = 9, index_of(">") = 5, end < start → no extraction
        fail_if(keys[0].email != null,
            "GPG: malformed brackets (> before <) must not extract email");
    }

    /* ===== Fingerprint / key ID ===== */

    private void test_keyid_from_fpr() {
        string fpr40 = "ABCDEF1234567890ABCDEF1234567890ABCDEF12";
        string output = "pub:u:::::::::\nfpr:::::::::" + fpr40 + ":\nuid:::::::::Test <t@t.com>:\n";
        var keys = GPGHelper.parse_keylist_output(output);
        fail_if_not_eq_int(keys.size, 1, "GPG: key must be parsed");
        fail_if_not_eq_str(keys[0].fpr, fpr40,
            "GPG: full 40-char fingerprint must be stored");
        // keyid = last 16 chars
        fail_if_not_eq_str(keys[0].keyid, "34567890ABCDEF12",
            "GPG: keyid must be last 16 chars of fingerprint");
    }

    private void test_short_fingerprint() {
        // Fingerprint shorter than 16 chars — edge case
        string short_fpr = "ABCDEF";
        string output = "pub:u:::::::::\nfpr:::::::::" + short_fpr + ":\nuid:::::::::Test <t@t.com>:\n";
        var keys = GPGHelper.parse_keylist_output(output);
        fail_if_not_eq_int(keys.size, 1, "GPG: key with short fpr must be parsed");
        // keyid should be same as fpr when < 16 chars
        fail_if_not_eq_str(keys[0].keyid, short_fpr,
            "GPG: short fingerprint must be used as keyid directly");
    }

    /* ===== Subkeys ===== */

    private void test_subkey_fpr_skipped() {
        // ssb record should reset expect_fpr, so its fpr line is ignored
        string output = string.join("\n",
            "pub:u:::::::::",
            "fpr:::::::::AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555:",
            "uid:::::::::Main Key <main@example.com>:",
            "ssb:u:::::::::",
            "fpr:::::::::FFFF6666GGGG7777HHHH8888IIII9999JJJJ0000:",
            ""
        );
        var keys = GPGHelper.parse_keylist_output(output);
        fail_if_not_eq_int(keys.size, 1, "GPG: subkey must not create separate key");
        fail_if_not_eq_str(keys[0].fpr, "AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555",
            "GPG: primary key fingerprint must be used, not subkey");
    }

    private void test_decrypt_key_match_secret_primary() {
        string output = string.join("\n",
            "sec:u:4096:1:D7AF69239B217F82:1778926063:1841998063::u:::escaESCA:::+:::23::0:",
            "fpr:::::::::2D13DEC36B1468057836C325D7AF69239B217F82:",
            "uid:u::::1778926063::HASH::lid <linuxinvite@dinox.im>::::::::::0:",
            "ssb:u:4096:1:C98AA6F84EEAE130:1778926063:1841998063:::::esa:::+:::23:",
            "fpr:::::::::A90DE8389E3938F449356D8AC98AA6F84EEAE130:",
            ""
        );
        var recipients = new ArrayList<string>();
        recipients.add("D7AF69239B217F82");
        string? key = GPGHelper.find_secret_primary_for_recipient_keyids(output, recipients);
        fail_if_null(key, "GPG: primary recipient keyid must match secret primary");
        fail_if_not_eq_str(key, "2D13DEC36B1468057836C325D7AF69239B217F82",
            "GPG: decryption key must be the primary fingerprint");
    }

    private void test_decrypt_key_match_secret_subkey() {
        string output = string.join("\n",
            "sec:u:4096:1:D7AF69239B217F82:1778926063:1841998063::u:::escaESCA:::+:::23::0:",
            "fpr:::::::::2D13DEC36B1468057836C325D7AF69239B217F82:",
            "uid:u::::1778926063::HASH::lid <linuxinvite@dinox.im>::::::::::0:",
            "ssb:u:4096:1:C98AA6F84EEAE130:1778926063:1841998063:::::esa:::+:::23:",
            "fpr:::::::::A90DE8389E3938F449356D8AC98AA6F84EEAE130:",
            ""
        );
        var recipients = new ArrayList<string>();
        recipients.add("C98AA6F84EEAE130");
        string? key = GPGHelper.find_secret_primary_for_recipient_keyids(output, recipients);
        fail_if_null(key, "GPG: subkey recipient keyid must match secret subkey");
        fail_if_not_eq_str(key, "2D13DEC36B1468057836C325D7AF69239B217F82",
            "GPG: subkey match must return the owning primary fingerprint");
    }

    private void test_decrypt_key_no_match() {
        string output = string.join("\n",
            "sec:u:4096:1:D7AF69239B217F82:1778926063:1841998063::u:::escaESCA:::+:::23::0:",
            "fpr:::::::::2D13DEC36B1468057836C325D7AF69239B217F82:",
            "uid:u::::1778926063::HASH::lid <linuxinvite@dinox.im>::::::::::0:",
            "ssb:u:4096:1:C98AA6F84EEAE130:1778926063:1841998063:::::esa:::+:::23:",
            "fpr:::::::::A90DE8389E3938F449356D8AC98AA6F84EEAE130:",
            ""
        );
        var recipients = new ArrayList<string>();
        recipients.add("0000000000000000");
        string? key = GPGHelper.find_secret_primary_for_recipient_keyids(output, recipients);
        fail_if(key != null, "GPG: unrelated recipient keyid must not match a secret key");
    }

    /* ===== Multiple keys ===== */

    private void test_multiple_keys() {
        string output = string.join("\n",
            "pub:u:::::::::",
            "fpr:::::::::AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555:",
            "uid:::::::::Alice <alice@a.com>:",
            "pub:u:::::::::",
            "fpr:::::::::1111222233334444555566667777888899990000:",
            "uid:::::::::Bob <bob@b.com>:",
            ""
        );
        var keys = GPGHelper.parse_keylist_output(output);
        fail_if_not_eq_int(keys.size, 2, "GPG: two pub keys must produce 2 entries");
        fail_if_not_eq_str(keys[0].uid, "Alice <alice@a.com>",
            "GPG: first key uid must be Alice");
        fail_if_not_eq_str(keys[1].uid, "Bob <bob@b.com>",
            "GPG: second key uid must be Bob");
    }

    /* ===== Edge cases ===== */

    private void test_no_uid_no_add() {
        // Key with fpr but no uid record — must NOT be added
        string output = "pub:u:::::::::\nfpr:::::::::ABCDEF1234567890ABCDEF1234567890ABCDEF12:\n";
        var keys = GPGHelper.parse_keylist_output(output);
        fail_if_not_eq_int(keys.size, 0,
            "GPG: key without uid must not be added to list");
    }

    private void test_no_fpr_no_add() {
        // Key with uid but no fpr (empty fingerprint) — must NOT be added
        string output = "pub:u:::::::::\nuid:::::::::Name <n@n.com>:\n";
        var keys = GPGHelper.parse_keylist_output(output);
        fail_if_not_eq_int(keys.size, 0,
            "GPG: key without fingerprint must not be added to list");
    }

    private void test_malformed_lines() {
        // Lines with < 2 fields, random garbage
        string output = "garbage\n:\npub\nfpr:::::::::FPR40CHARS000000000000000000000000FPR40CH:\nuid:::::::::OK <ok@ok.com>:\n";
        var keys = GPGHelper.parse_keylist_output(output);
        // "pub" alone has only 1 field after split(":") → parts.length < 2 → skipped
        // But actually "pub" has no colons, so split(":") gives ["pub"] → length 1 → skipped
        // So no current_key is set, fpr and uid are attached to nothing
        // FINDING: a "pub" line without colons is silently ignored
        fail_if_not_eq_int(keys.size, 0,
            "GPG: malformed pub line (no colons) must not create key");
    }

    private void test_only_first_uid() {
        // Multiple uid records — only first should be captured
        string output = string.join("\n",
            "pub:u:::::::::",
            "fpr:::::::::ABCDEF1234567890ABCDEF1234567890ABCDEF12:",
            "uid:::::::::First UID <first@example.com>:",
            "uid:::::::::Second UID <second@example.com>:",
            ""
        );
        var keys = GPGHelper.parse_keylist_output(output);
        fail_if_not_eq_int(keys.size, 1, "GPG: multiple UIDs must still produce 1 key");
        fail_if_not_eq_str(keys[0].uid, "First UID <first@example.com>",
            "GPG: only first UID must be captured (parser checks uid == null)");
        fail_if_not_eq_str(keys[0].email, "first@example.com",
            "GPG: email must come from first UID");
    }
}

}
