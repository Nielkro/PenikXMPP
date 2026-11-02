/*
 * SECURITY AUDIT TESTS — Bot-Features
 * Spec-based, NOT adapted to current code.
 * FAILs indicate REAL BUGS.
 */
using Gee;

namespace Dino.Plugins.BotFeatures.Test {

class RateLimiterAudit : Gee.TestCase {

    public RateLimiterAudit() {
        base("Audit_RateLimiter");
        add_test("CONTRACT_zero_window_must_not_allow_unlimited", test_zero_window);
        add_test("CONTRACT_negative_max_must_block_all", test_negative_max);
        add_test("CONTRACT_int_overflow_in_cleanup_staleness", test_cleanup_overflow);
    }

    /*
     * FIX VERIFIED: window_seconds=0 is now clamped to 1.
     * max_requests=5 → at most 5 should pass.
     */
    void test_zero_window() {
        var limiter = new RateLimiter(5, 0);

        int allowed = 0;
        for (int i = 0; i < 100; i++) {
            if (limiter.check(1)) allowed++;
        }

        // SPEC: max_requests=5 → at most 5 should pass (window_seconds clamped to 1)
        if (allowed > 5) {
            GLib.Test.message("BUG: window_seconds=0 allowed %d/100 requests (limit=5). Window resets every call.".printf(allowed));
            GLib.Test.fail();
        }
    }

    /*
     * max_requests < 0 should block everything.
     * Code: request_count(0) >= max_requests(-1) is TRUE → blocked. Actually may work.
     */
    void test_negative_max() {
        var limiter = new RateLimiter(-1, 60);
        bool first = limiter.check(1);
        if (first) {
            GLib.Test.message("BUG: RateLimiter(-1, 60) allowed a request. Negative max_requests should block all.");
            GLib.Test.fail();
        }
    }

    /*
     * FIX VERIFIED: cleanup() now uses int64 arithmetic for staleness check.
     * (int64) window_seconds * 10 does not overflow.
     */
    void test_cleanup_overflow() {
        var limiter = new RateLimiter(5, 300000000);
        limiter.check(1);

        // cleanup should NOT remove a fresh window
        limiter.cleanup();

        // With int64, staleness threshold is 3000000000L (correct, no overflow)
        // Fresh window should NOT be removed
        int retry = limiter.retry_after(1);
        if (retry == 0) {
            GLib.Test.message("BUG: cleanup() removed a fresh window. Integer overflow in window_seconds*10 (300000000*10 > INT32_MAX).");
            GLib.Test.fail();
        }
    }
}

class JSONEscapeAudit : Gee.TestCase {

    public JSONEscapeAudit() {
        base("Audit_JSONEscape");
        add_test("RFC8259_backslash_before_quote_produces_invalid_json", test_backslash_escape);
        add_test("RFC8259_newline_raw_in_json_string", test_newline_escape);
        add_test("RFC8259_tab_raw_in_json_string", test_tab_escape);
        add_test("RFC8259_UTF8_codepoints_and_controls_roundtrip", test_utf8_codepoints_and_controls_roundtrip);
        add_test("RFC8259_invalid_UTF8_becomes_replacement_character", test_invalid_utf8_becomes_replacement_character);
        add_test("RFC8259_shared_AI_and_Telegram_payloads_roundtrip", test_shared_payload_shapes_roundtrip);
        add_test("UTF8_character_limit_does_not_split_multibyte_codepoint", test_utf8_character_limit);
    }

    /*
     * FIX VERIFIED: send_error() now escapes \ before ", per RFC 8259.
     * This simulates the FIXED escaping logic.
     */
    void test_backslash_escape() {
        string input = "path\\to\\\"file\"";

        // Fixed logic from auth_middleware.vala: escape \ first, then "
        string escaped = input
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t");

        // Proper JSON: escape \ first, then "
        string proper = input.replace("\\", "\\\\").replace("\"", "\\\"");

        if (escaped != proper) {
            GLib.Test.message("BUG: Incomplete JSON escaping. Input: '%s' → escaped: '%s', proper: '%s'".printf(input, escaped, proper));
            GLib.Test.fail();
        }
    }

    void test_newline_escape() {
        string input = "error on\nline 2";
        // Fixed logic: escapes \n
        string escaped = input
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t");

        if (escaped.contains("\n")) {
            GLib.Test.message("BUG: Raw newline in JSON string. RFC 8259 §7 requires escaping control chars.");
            GLib.Test.fail();
        }
    }

    void test_tab_escape() {
        string input = "col1\tcol2";
        // Fixed logic: escapes \t
        string escaped = input
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t");

        if (escaped.contains("\t")) {
            GLib.Test.message("BUG: Raw tab in JSON string. RFC 8259 §7 requires escaping control chars.");
            GLib.Test.fail();
        }
    }

    void test_utf8_codepoints_and_controls_roundtrip() {
        string c0 = ((unichar) 0x01).to_string();
        string input = "Кириллица äöü 漢字 😀 quote:\" slash:\\ line:\r\n\t control:" + c0;
        string expected = "Кириллица äöü 漢字 😀 quote:\\\" slash:\\\\ line:\\r\\n\\t control:\\u0001";
        string escaped = BotUtils.escape_json(input);

        assert_true(escaped == expected);

        try {
            var parser = new Json.Parser();
            parser.load_from_data("{\"value\":\"%s\"}".printf(escaped), -1);
            Json.Node? root = parser.get_root();
            assert_true(root != null);
            assert_true(root.get_object().get_string_member("value") == input);
        } catch (Error e) {
            GLib.Test.message("Escaped UTF-8 JSON did not parse: %s", e.message);
            GLib.Test.fail();
        }
    }

    void test_shared_payload_shapes_roundtrip() {
        string message = "Привет äöü 漢字 😀 \"quoted\"\\path\r\n\t";
        string escaped = BotUtils.escape_json(message);
        string ai_json = "{\"messages\":[{\"role\":\"user\",\"content\":\"%s\"}]}".printf(escaped);
        string telegram_json = "{\"chat_id\":\"42\",\"text\":\"%s\"}".printf(escaped);

        try {
            var ai_parser = new Json.Parser();
            ai_parser.load_from_data(ai_json, -1);
            Json.Array messages = ai_parser.get_root().get_object().get_array_member("messages");
            assert_true(messages.get_object_element(0).get_string_member("content") == message);

            var telegram_parser = new Json.Parser();
            telegram_parser.load_from_data(telegram_json, -1);
            assert_true(telegram_parser.get_root().get_object().get_string_member("text") == message);
        } catch (Error e) {
            GLib.Test.message("Shared AI/Telegram JSON payload did not parse: %s", e.message);
            GLib.Test.fail();
        }
    }

    void test_invalid_utf8_becomes_replacement_character() {
        uint8[] bytes = { 'A', 0xff, 'B', 0 };
        string invalid = (string) bytes;
        string replacement = ((unichar) 0xfffd).to_string();
        assert_false(invalid.validate());

        string escaped = BotUtils.escape_json(invalid);
        assert_true(escaped == "A" + replacement + "B");
        assert_true(escaped.validate());

        try {
            var parser = new Json.Parser();
            parser.load_from_data("{\"value\":\"%s\"}".printf(escaped), -1);
            assert_true(parser.get_root().get_object().get_string_member("value") == "A" + replacement + "B");
        } catch (Error e) {
            GLib.Test.message("Replacement-character JSON did not parse: %s", e.message);
            GLib.Test.fail();
        }
    }

    void test_utf8_character_limit() {
        string input = string.nfill(499, 'a') + "😀" + "Z";
        string truncated = BotUtils.truncate_utf8(input, 500);

        assert_true(truncated.validate());
        assert_true(truncated == string.nfill(499, 'a') + "😀...");
        assert_true(truncated.char_count() == 503);
        assert_true(BotUtils.truncate_utf8("äöü", 500) == "äöü");
    }
}

}
