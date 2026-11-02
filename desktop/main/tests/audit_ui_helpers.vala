using Gee;
using Gdk;

namespace Dino.Ui.Test {

/**
 * Security Audit: UI Helper Pure Functions
 *
 * Tests namespace-level functions in Dino.Ui.Util (helper.vala)
 * that are pure logic with no GTK widget instantiation.
 *
 * Covers:
 *   - Presence color mapping (XMPP show values)
 *   - RGBA to hex string conversion
 *   - 24h format flag
 *   - DateTime formatting
 *   - URL detection regex (security-critical: prevents phishing link misparse)
 *   - Bracket matching pairs
 *   - Whitespace summarization
 *   - Emoji counting (ICU-based)
 *   - Text markup formatting (bold/italic/code/strikethrough)
 */
class UiHelperAudit : Gee.TestCase {

    public UiHelperAudit() {
        base("UiHelperAudit");

        // Presence colors
        add_test("XMPP_color_for_show_online", test_color_online);
        add_test("XMPP_color_for_show_away", test_color_away);
        add_test("XMPP_color_for_show_chat", test_color_chat);
        add_test("XMPP_color_for_show_xa", test_color_xa);
        add_test("XMPP_color_for_show_dnd", test_color_dnd);
        add_test("XMPP_color_for_show_unknown_default", test_color_unknown);

        // RGBA hex conversion
        add_test("CONTRACT_rgba_to_hex_red", test_rgba_red);
        add_test("CONTRACT_rgba_to_hex_green", test_rgba_green);
        add_test("CONTRACT_rgba_to_hex_blue", test_rgba_blue);
        add_test("CONTRACT_rgba_to_hex_white", test_rgba_white);
        add_test("CONTRACT_rgba_to_hex_transparent", test_rgba_transparent);
        add_test("CONTRACT_rgba_to_hex_clamp_overflow", test_rgba_clamp);

        // Time format
        add_test("CONTRACT_is_24h_format_returns_true", test_is_24h);
        add_test("CONTRACT_format_time_24h", test_format_time_24h);
        add_test("CONTRACT_format_time_uses_24h_branch", test_format_time_branch);

        // URL regex
        add_test("RFC3986_url_regex_matches_https", test_url_https);
        add_test("RFC3986_url_regex_matches_http", test_url_http);
        add_test("RFC3986_url_regex_matches_xmpp", test_url_xmpp);
        add_test("RFC3986_url_regex_matches_mailto", test_url_mailto);
        add_test("RFC3986_url_regex_no_plain_text", test_url_no_plain);
        add_test("RFC3986_url_regex_matches_ftp", test_url_ftp);
        add_test("RFC3986_url_regex_embedded_in_text", test_url_embedded);

        // XMPP URI / invitation parsing
        add_test("XMPP_uri_parse_chat_invite", test_xmpp_uri_chat_invite);
        add_test("XMPP_uri_parse_muc_invite", test_xmpp_uri_muc_invite);
        add_test("XMPP_uri_parse_roster_preauth_name", test_xmpp_uri_roster_preauth_name);
        add_test("XMPP_uri_parse_register_preauth", test_xmpp_uri_register_preauth);
        add_test("XMPP_uri_parse_percent_decoding", test_xmpp_uri_percent_decoding);
        add_test("XMPP_uri_parse_rejects_non_xmpp", test_xmpp_uri_rejects_non_xmpp);
        add_test("XMPP_uri_unknown_query_is_not_chat", test_xmpp_uri_unknown_query_is_not_chat);

        // Matching chars
        add_test("CONTRACT_matching_chars_paren", test_match_paren);
        add_test("CONTRACT_matching_chars_bracket", test_match_bracket);
        add_test("CONTRACT_matching_chars_brace", test_match_brace);

        // Whitespace summarization
        add_test("CONTRACT_summarize_ws_multiple_spaces", test_ws_spaces);
        add_test("CONTRACT_summarize_ws_tabs", test_ws_tabs);
        add_test("CONTRACT_summarize_ws_newlines", test_ws_newlines);
        add_test("CONTRACT_summarize_ws_mixed", test_ws_mixed);
        add_test("CONTRACT_summarize_ws_no_change", test_ws_no_change);
        add_test("CONTRACT_summarize_ws_empty", test_ws_empty);

        // Emoji counting (ICU)
        add_test("ICU_emoji_count_single", test_emoji_single);
        add_test("ICU_emoji_count_multiple", test_emoji_multiple);
        add_test("ICU_emoji_count_text_returns_neg1", test_emoji_text);
        add_test("ICU_emoji_count_mixed_returns_neg1", test_emoji_mixed);
        add_test("ICU_emoji_count_empty", test_emoji_empty);
        add_test("ICU_emoji_count_zwj_sequence", test_emoji_zwj);
        add_test("ICU_emoji_count_variation_selector", test_emoji_vs16);

        // Text markup
        add_test("CONTRACT_sanitize_utf8_invalid_bytes", test_sanitize_utf8_invalid_bytes);
        add_test("CONTRACT_sanitize_utf8_with_length_invalid_bytes", test_sanitize_utf8_with_length_invalid_bytes);
        add_test("CONTRACT_sanitize_utf8_preserves_emoji_sequences", test_sanitize_utf8_preserves_emoji_sequences);
        add_test("CONTRACT_sanitize_utf8_code_paste_invalid_bytes", test_sanitize_utf8_code_paste_invalid_bytes);
        add_test("CONTRACT_markup_bold", test_markup_bold);
        add_test("CONTRACT_markup_italic", test_markup_italic);
        add_test("CONTRACT_markup_code", test_markup_code);
        add_test("CONTRACT_markup_strikethrough", test_markup_strike);
        add_test("CONTRACT_markup_plain_no_change", test_markup_plain);
        add_test("CONTRACT_markup_link_detection", test_markup_link);
        add_test("CONTRACT_markup_link_after_unsupported_uri", test_markup_link_after_unsupported_uri);
        add_test("CONTRACT_markup_link_unicode_byte_offsets", test_markup_link_unicode_byte_offsets);
        add_test("CONTRACT_markup_link_trailing_punctuation", test_markup_link_trailing_punctuation);
        add_test("CONTRACT_markup_xmpp_command_escaped_display", test_markup_xmpp_command_escaped_display);
        add_test("CONTRACT_markup_unicode_byte_offsets", test_markup_unicode_byte_offsets);
        add_test("CONTRACT_markup_quote_unicode_byte_offsets", test_markup_quote_unicode_byte_offsets);
        add_test("CONTRACT_markup_escaped_quote_unicode_byte_offsets", test_markup_escaped_quote_unicode_byte_offsets);
        add_test("CONTRACT_markup_highlight_word", test_markup_highlight);
        add_test("CONTRACT_markup_highlight_unicode_byte_offsets", test_markup_highlight_unicode_byte_offsets);
        add_test("CONTRACT_markup_escape_entities", test_markup_escape);

        // Optional attachment thumbnails
        add_test("CONTRACT_thumbnail_unsupported_uses_fallback", test_thumbnail_unsupported_uses_fallback);
        add_test("CONTRACT_thumbnail_invalid_uses_fallback", test_thumbnail_invalid_uses_fallback);
        add_test("CONTRACT_thumbnail_selects_supported_image", test_thumbnail_selects_supported_image);
        add_test("CONTRACT_thumbnail_preserves_small_dimensions", test_thumbnail_preserves_small_dimensions);
        add_test("SECURITY_thumbnail_bounds_input_pixels_and_output", test_thumbnail_limits);
        add_test("CONTRACT_thumbnail_async_yields_and_honors_cancellation", test_thumbnail_async);
    }

    // --- Presence Colors (XMPP RFC 6121 show values) ---

    private void test_color_online() {
        fail_if_not_eq_str("#9CCC65", Util.color_for_show("online"));
    }

    private void test_color_away() {
        fail_if_not_eq_str("#FFCA28", Util.color_for_show("away"));
    }

    private void test_color_chat() {
        fail_if_not_eq_str("#66BB6A", Util.color_for_show("chat"));
    }

    private void test_color_xa() {
        fail_if_not_eq_str("#EF5350", Util.color_for_show("xa"));
    }

    private void test_color_dnd() {
        fail_if_not_eq_str("#EF5350", Util.color_for_show("dnd"));
    }

    private void test_color_unknown() {
        fail_if_not_eq_str("#BDBDBD", Util.color_for_show("offline"));
        fail_if_not_eq_str("#BDBDBD", Util.color_for_show(""));
        fail_if_not_eq_str("#BDBDBD", Util.color_for_show("bogus"));
    }

    // --- RGBA to Hex ---

    private void test_rgba_red() {
        Gdk.RGBA red = { 1.0f, 0.0f, 0.0f, 1.0f };
        fail_if_not_eq_str("#FF0000FF", Util.rgba_to_hex(red));
    }

    private void test_rgba_green() {
        Gdk.RGBA green = { 0.0f, 1.0f, 0.0f, 1.0f };
        fail_if_not_eq_str("#00FF00FF", Util.rgba_to_hex(green));
    }

    private void test_rgba_blue() {
        Gdk.RGBA blue = { 0.0f, 0.0f, 1.0f, 1.0f };
        fail_if_not_eq_str("#0000FFFF", Util.rgba_to_hex(blue));
    }

    private void test_rgba_white() {
        Gdk.RGBA white = { 1.0f, 1.0f, 1.0f, 1.0f };
        fail_if_not_eq_str("#FFFFFFFF", Util.rgba_to_hex(white));
    }

    private void test_rgba_transparent() {
        Gdk.RGBA transparent = { 0.0f, 0.0f, 0.0f, 0.0f };
        fail_if_not_eq_str("#00000000", Util.rgba_to_hex(transparent));
    }

    private void test_rgba_clamp() {
        // Values > 1.0 should be clamped to 1.0
        Gdk.RGBA over = { 2.0f, -1.0f, 0.5f, 1.0f };
        // red=2.0 clamped to 1.0 → FF, green=-1.0 clamped to 0.0 → 00
        fail_if_not_eq_str("#FF0080FF", Util.rgba_to_hex(over));
    }

    // --- Time Format ---

    private void test_is_24h() {
        assert_true(Util.is_24h_format(), "is_24h_format should return true");
    }

    private void test_format_time_24h() {
        var dt = new DateTime.local(2026, 2, 23, 14, 30, 0);
        string result = Util.format_time(dt, "%H∶%M", "%l∶%M %p");
        // Since is_24h_format() returns true, should use 24h format
        assert_true(result.contains("14"), "24h format should contain '14' for 2:30 PM");
    }

    private void test_format_time_branch() {
        var dt = new DateTime.local(2026, 1, 1, 9, 5, 0);
        string result = Util.format_time(dt, "TWENTY_FOUR", "TWELVE");
        // is_24h_format() returns true → should pick format_24h
        assert_true(result == "TWENTY_FOUR", "format_time should select 24h format string");
    }

    // --- URL Regex ---

    private void test_url_https() {
        var regex = Util.get_url_regex();
        assert_true(regex.match("https://example.com"), "Should match https URL");
    }

    private void test_url_http() {
        var regex = Util.get_url_regex();
        assert_true(regex.match("http://example.com/path?q=1"), "Should match http URL with path");
    }

    private void test_url_xmpp() {
        var regex = Util.get_url_regex();
        assert_true(regex.match("xmpp:user@example.com"), "Should match xmpp: URI");
    }

    private void test_url_mailto() {
        var regex = Util.get_url_regex();
        assert_true(regex.match("mailto:user@example.com"), "Should match mailto: URI");
    }

    private void test_url_no_plain() {
        var regex = Util.get_url_regex();
        assert_false(regex.match("just plain text"), "Should NOT match plain text");
    }

    private void test_url_ftp() {
        var regex = Util.get_url_regex();
        assert_true(regex.match("ftp://files.example.com/pub"), "Should match ftp URL");
    }

    private void test_url_embedded() {
        var regex = Util.get_url_regex();
        MatchInfo info;
        regex.match("Check out https://example.com/page for details", 0, out info);
        assert_true(info.matches(), "Should match URL embedded in text");
        string url = info.fetch(0);
        assert_true(url.has_prefix("https://example.com"), "Extracted URL should start with https://example.com");
    }

    private void test_xmpp_uri_chat_invite() {
        var info = Dino.parse_xmpp_uri("xmpp:romeo@example.org");
        assert_true(info != null, "chat URI should parse");
        fail_if_not_eq_str("romeo@example.org", info.jid);
        fail_if_not_eq_str("message", info.query);
        assert_true(info.kind == Dino.XmppUriKind.CHAT, "default xmpp URI should be chat");
        assert_false(info.has_preauth, "plain chat invite should not have preauth");
    }

    private void test_xmpp_uri_muc_invite() {
        var info = Dino.parse_xmpp_uri("xmpp:room@conference.example.org?join");
        assert_true(info != null, "MUC URI should parse");
        fail_if_not_eq_str("room@conference.example.org", info.jid);
        fail_if_not_eq_str("join", info.query);
        assert_true(info.kind == Dino.XmppUriKind.MUC, "?join should be MUC invite");
    }

    private void test_xmpp_uri_roster_preauth_name() {
        var info = Dino.parse_xmpp_uri("xmpp:juliet@example.org?roster;preauth=token-123;name=Juliet%20Capulet");
        assert_true(info != null, "roster preauth URI should parse");
        fail_if_not_eq_str("juliet@example.org", info.jid);
        fail_if_not_eq_str("roster", info.query);
        assert_true(info.kind == Dino.XmppUriKind.CHAT, "?roster should be a contact invite");
        assert_true(info.has_preauth, "roster invite should expose preauth presence");
        fail_if_not_eq_str("token-123", info.options["preauth"]);
        fail_if_not_eq_str("Juliet Capulet", info.options["name"]);
    }

    private void test_xmpp_uri_register_preauth() {
        var info = Dino.parse_xmpp_uri("xmpp:example.org?register;preauth=abc123");
        assert_true(info != null, "register URI should parse");
        fail_if_not_eq_str("example.org", info.jid);
        fail_if_not_eq_str("register", info.query);
        assert_true(info.kind == Dino.XmppUriKind.REGISTER, "?register should be account invite");
        assert_true(info.has_preauth, "register invite should expose preauth presence");
        fail_if_not_eq_str("abc123", info.options["preauth"]);

        info = Dino.parse_xmpp_uri("xmpp:dinox.im?register;preauth=testToken123456");
        assert_true(info != null, "CloudBot account invite URI should parse");
        fail_if_not_eq_str("dinox.im", info.jid);
        assert_true(info.kind == Dino.XmppUriKind.REGISTER, "CloudBot invite should be account registration");
        fail_if_not_eq_str("testToken123456", info.options["preauth"]);
    }

    private void test_xmpp_uri_percent_decoding() {
        var info = Dino.parse_xmpp_uri("xmpp:room%2Btest@conference.example.org?join;preauth=a%2Bb%3D");
        assert_true(info != null, "percent-encoded URI should parse");
        fail_if_not_eq_str("room+test@conference.example.org", info.jid);
        fail_if_not_eq_str("a+b=", info.options["preauth"]);
    }

    private void test_xmpp_uri_rejects_non_xmpp() {
        assert_true(Dino.parse_xmpp_uri("https://example.org/#romeo@example.org") == null, "non-xmpp URI should be rejected");
        assert_true(Dino.parse_xmpp_uri("xmpp:?register;preauth=abc") == null, "empty target should be rejected");
    }

    private void test_xmpp_uri_unknown_query_is_not_chat() {
        var info = Dino.parse_xmpp_uri("xmpp:example.org?unknown;preauth=abc");
        assert_true(info != null, "unknown query URI should parse");
        assert_true(info.kind == Dino.XmppUriKind.UNKNOWN, "unknown query should not be treated as chat");
    }

    // --- Matching Chars ---

    private void test_match_paren() {
        var map = Util.get_matching_chars();
        assert_true(map.has_key(')'), "Should map ) → (");
        assert_true(map[')'] == '(', "Close paren should map to open paren");
    }

    private void test_match_bracket() {
        var map = Util.get_matching_chars();
        assert_true(map.has_key(']'), "Should map ] → [");
        assert_true(map[']'] == '[', "Close bracket should map to open bracket");
    }

    private void test_match_brace() {
        var map = Util.get_matching_chars();
        assert_true(map.has_key('}'), "Should map } → {");
        assert_true(map['}'] == '{', "Close brace should map to open brace");
    }

    // --- Whitespace Summarization ---

    private void test_ws_spaces() {
        fail_if_not_eq_str("a b c", Util.summarize_whitespaces_to_space("a  b   c"));
    }

    private void test_ws_tabs() {
        fail_if_not_eq_str("a b", Util.summarize_whitespaces_to_space("a\tb"));
    }

    private void test_ws_newlines() {
        fail_if_not_eq_str("a b", Util.summarize_whitespaces_to_space("a\nb"));
    }

    private void test_ws_mixed() {
        fail_if_not_eq_str("a b c", Util.summarize_whitespaces_to_space("a \t\n b \n\t c"));
    }

    private void test_ws_no_change() {
        fail_if_not_eq_str("hello world", Util.summarize_whitespaces_to_space("hello world"));
    }

    private void test_ws_empty() {
        fail_if_not_eq_str("", Util.summarize_whitespaces_to_space(""));
    }

    // --- Emoji Count (ICU) ---

    private void test_emoji_single() {
        int count = Util.get_only_emoji_count("😀");
        fail_if_not_eq_int(1, count);
    }

    private void test_emoji_multiple() {
        int count = Util.get_only_emoji_count("😀😀😀");
        fail_if_not_eq_int(3, count);
    }

    private void test_emoji_text() {
        int count = Util.get_only_emoji_count("hello");
        fail_if_not_eq_int(-1, count);
    }

    private void test_emoji_mixed() {
        int count = Util.get_only_emoji_count("hello 😀");
        fail_if_not_eq_int(-1, count);
    }

    private void test_emoji_empty() {
        int count = Util.get_only_emoji_count("");
        fail_if_not_eq_int(0, count);
    }

    private void test_emoji_zwj() {
        // Family emoji: Person + ZWJ + Person + ZWJ + Child
        // 👨‍👩‍👧 = U+1F468 U+200D U+1F469 U+200D U+1F467
        int count = Util.get_only_emoji_count("👨\u200D👩\u200D👧");
        fail_if_not_eq_int(1, count);
    }

    private void test_emoji_vs16() {
        // Digit + VS16 = emoji presentation
        // 1️⃣ = U+0031 U+FE0F U+20E3
        int count = Util.get_only_emoji_count("1\uFE0F\u20E3");
        fail_if_not_eq_int(1, count);
    }

    // --- Text Markup ---

    private void test_sanitize_utf8_invalid_bytes() {
        uint8[] bytes = { 'o', 'k', 0xff, 'x', 0 };
        string invalid = (string) bytes;
        string result = Util.sanitize_utf8(invalid);
        assert_true(result.validate(), "Sanitized UI text must be valid UTF-8");
        assert_true(result.contains("ok"), "Valid prefix should be preserved");
        assert_true(result.contains("x"), "Valid suffix should be preserved");
    }

    private void test_sanitize_utf8_with_length_invalid_bytes() {
        uint8[] bytes = { 'o', 'k', 0, 0xff, 'x', 0 };
        string invalid = (string) bytes;
        string result = Util.sanitize_utf8_with_length(invalid, 5);
        assert_true(result.validate(), "Length-aware sanitized UI text must be valid UTF-8");
        assert_true(result.contains("ok"), "Valid prefix before embedded NUL should be preserved");
    }

    private void test_sanitize_utf8_preserves_emoji_sequences() {
        string emoji_text = "🙂 😀 😉 😇 😈 😮 😛 😜 🙁 😢 😕 ❤️ 😘️";
        string result = Util.sanitize_utf8(emoji_text);
        assert_true(result.validate(), "Emoji text must stay valid UTF-8");
        fail_if_not_eq_str(emoji_text, result);
    }

    private void test_sanitize_utf8_code_paste_invalid_bytes() {
        uint8[] bytes = { '`', '`', '`', '\n', 'i', 'f', ' ', '(', 'a', ' ', '=', '=', ' ', 0xff, ')', ' ', '{', '\n', ' ', ' ', 'r', 'e', 't', 'u', 'r', 'n', ' ', ':', ')', ';', '\n', '}', '\n', '`', '`', '`', 0 };
        string invalid = (string) bytes;
        string result = Util.sanitize_utf8_with_length(invalid, bytes.length - 1);
        assert_true(result.validate(), "Sanitized pasted code must be valid UTF-8");
        assert_true(result.contains("```"), "Code fence should be preserved");
        assert_true(result.contains("return :)"), "ASCII code content should be preserved");
    }

    private void test_markup_bold() {
        string result = Util.parse_add_markup("hello *world*", null, false, true);
        assert_true(result.contains("<b>"), "*word* should produce <b> tag");
        assert_true(result.contains("world"), "bold text content should be preserved");
    }

    private void test_markup_italic() {
        string result = Util.parse_add_markup("hello _world_", null, false, true);
        assert_true(result.contains("<i>"), "_word_ should produce <i> tag");
    }

    private void test_markup_code() {
        string result = Util.parse_add_markup("hello `code`", null, false, true);
        assert_true(result.contains("<tt>"), "`word` should produce <tt> tag");
    }

    private void test_markup_strike() {
        string result = Util.parse_add_markup("hello ~strike~", null, false, true);
        assert_true(result.contains("<s>"), "~word~ should produce <s> tag");
    }

    private void test_markup_plain() {
        string result = Util.parse_add_markup("hello world", null, false, false);
        // With parse_text_markup=false and parse_links=false, just escape
        assert_true(result == "hello world", "Plain text without markup should pass through");
    }

    private void test_markup_link() {
        string result = Util.parse_add_markup("visit https://example.com now", null, true, false);
        assert_true(result.contains("<a href="), "URL should be wrapped in <a> tag");
        assert_true(result.contains("https://example.com"), "URL should be preserved in link");
    }

    private void test_markup_link_after_unsupported_uri() {
        // URNs match the detector but are not clickable. Advancing to the next
        // match must keep the subject alive (also exercise this under Valgrind).
        string result = Util.parse_add_markup("urn:example:ignored https://example.org/Ä", null, true, false);
        fail_if_not_eq_str("urn:example:ignored <a href=\"https://example.org/Ä\">https://example.org/Ä</a>", result);
    }

    private void test_markup_link_unicode_byte_offsets() {
        // Lowercasing İ adds a byte; lowercasing K removes two bytes. Neither
        // transformation may move slices in the original message or URL.
        foreach (string prefix in new string[]{"İ", "K", "İK"}) {
            string url = "https://example.org/İ/K/Ä";
            string result = Util.parse_add_markup(prefix + " " + url, null, true, false);
            assert_true(result.validate(), "Link markup must remain valid UTF-8");
            fail_if_not_eq_str(prefix + " <a href=\"" + url + "\">" + url + "</a>", result);
        }
    }

    private void test_markup_link_trailing_punctuation() {
        string result = Util.parse_add_markup("İ https://example.org/(Ä))»", null, true, false);
        fail_if_not_eq_str("İ <a href=\"https://example.org/(Ä)\">https://example.org/(Ä)</a>)»", result);
    }

    private void test_markup_xmpp_command_escaped_display() {
        string uri = "xmpp:bot@example.org?message;body=%3Cb%3E%C4%B0%3C%2Fb%3E";
        string result = Util.parse_add_markup(uri, null, true, false);
        fail_if_not_eq_str("<a href=\"" + uri + "\">&lt;b&gt;İ&lt;/b&gt;</a>", result);
    }

    private void test_markup_unicode_byte_offsets() {
        foreach (string prefix in new string[]{"İ", "K"}) {
            string result = Util.parse_add_markup(prefix + " *GRÜẞE*", null, false, true);
            assert_true(result.validate(), "Text markup must remain valid UTF-8");
            fail_if_not_eq_str(prefix + " <span color='#9E9E9E'>*</span><b>GRÜẞE</b><span color='#9E9E9E'>*</span>", result);
        }
    }

    private void test_markup_quote_unicode_byte_offsets() {
        string result = Util.parse_add_markup("İK\n> GRÜẞE", null, false, true);
        assert_true(result.validate(), "Quote markup must remain valid UTF-8");
        fail_if_not_eq_str("İK\n<span color='#707070'>> GRÜẞE</span>", result);
    }

    private void test_markup_escaped_quote_unicode_byte_offsets() {
        bool theme_dependent = false;
        string result = Util.parse_add_markup_theme("İK\n&gt; GRÜẞE &amp; Welt", null, false, false, true, true, ref theme_dependent, true);
        assert_true(theme_dependent, "Quote color must track the selected theme");
        assert_true(result.validate(), "Escaped quote markup must remain valid UTF-8");
        fail_if_not_eq_str("İK\n<span color='#BDBDBD'>&gt; GRÜẞE &amp; Welt</span>", result);
    }

    private void test_markup_highlight() {
        string result = Util.parse_add_markup("hello world", "world", false, false);
        assert_true(result.contains("<b>"), "Highlight word should be wrapped in <b>");
    }

    private void test_markup_highlight_unicode_byte_offsets() {
        string result = Util.parse_add_markup("İK GRÜẞE", "grüße", false, false);
        assert_true(result.validate(), "Highlight markup must remain valid UTF-8");
        fail_if_not_eq_str("İK <b>GRÜẞE</b>", result);
    }

    private void test_markup_escape() {
        string result = Util.parse_add_markup("<script>alert('xss')</script>", null, false, false);
        assert_true(result.contains("&lt;"), "< should be escaped to &lt;");
        assert_true(result.contains("&gt;"), "> should be escaped to &gt;");
        assert_false(result.contains("<script>"), "Raw <script> tag must NOT appear in output");
    }

    private Xmpp.Xep.JingleContentThumbnails.Thumbnail thumbnail_from_base64(string encoded, string media_type) {
        var thumbnail = new Xmpp.Xep.JingleContentThumbnails.Thumbnail();
        thumbnail.data = new Bytes(Base64.decode(encoded));
        thumbnail.media_type = media_type;
        return thumbnail;
    }

    private void test_thumbnail_unsupported_uses_fallback() {
        var thumbnails = new ArrayList<Xmpp.Xep.JingleContentThumbnails.Thumbnail>();
        foreach (string hash in new string[]{"RwgCAYCcaEOSmgiFX3cWXwk=", "0GcOFA5aumgIp3OJh3eldL+1CA==", "zAcKAwBHjQenhXtXRVAZsDM="}) {
            thumbnails.add(thumbnail_from_base64(hash, "image/thumbhash"));
        }
        assert_true(Util.get_thumbnail_preview(thumbnails) == null, "Unsupported thumbnails must leave the ordinary file/download fallback available");
    }

    private void test_thumbnail_invalid_uses_fallback() {
        var thumbnails = new ArrayList<Xmpp.Xep.JingleContentThumbnails.Thumbnail>();
        assert_true(Util.get_thumbnail_preview(thumbnails) == null, "Missing thumbnails must not produce an image preview");
        thumbnails.add(thumbnail_from_base64("", "image/png"));
        thumbnails.add(thumbnail_from_base64("bm90IGEgcG5n", "image/png"));
        assert_true(Util.get_thumbnail_preview(thumbnails) == null, "Empty or invalid images must not select an empty image preview");
    }

    private void test_thumbnail_selects_supported_image() {
        var thumbnails = new ArrayList<Xmpp.Xep.JingleContentThumbnails.Thumbnail>();
        thumbnails.add(thumbnail_from_base64("RwgCAYCcaEOSmgiFX3cWXwk=", "image/thumbhash"));
        thumbnails.add(thumbnail_from_base64("bm90IGEgcG5n", "image/png"));
        thumbnails.add(thumbnail_from_base64("iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAEElEQVR4nGP4z8AARAwoFABE0AX7pM/egAAAAABJRU5ErkJggg==", "image/png"));
        Gdk.Pixbuf? preview = Util.get_thumbnail_preview(thumbnails);
        assert_true(preview != null, "A later supported image must be used after optional unsupported thumbnails");
        if (preview == null) return;
        fail_if_not_eq_int(2, preview.width);
        fail_if_not_eq_int(3, preview.height);
    }

    private void test_thumbnail_preserves_small_dimensions() {
        var thumbnails = new ArrayList<Xmpp.Xep.JingleContentThumbnails.Thumbnail>();
        var thumbnail = thumbnail_from_base64("iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAEElEQVR4nGP4z8AARAwoFABE0AX7pM/egAAAAABJRU5ErkJggg==", "image/png");
        thumbnail.width = 4032;
        thumbnail.height = 3024;
        thumbnails.add(thumbnail);
        Gdk.Pixbuf? preview = Util.get_thumbnail_preview(thumbnails);
        assert_true(preview != null, "A supported image must produce a preview");
        if (preview == null) return;
        fail_if_not_eq_int(2, preview.width);
        fail_if_not_eq_int(3, preview.height);
    }

    private void test_thumbnail_limits() {
        var thumbnails = new ArrayList<Xmpp.Xep.JingleContentThumbnails.Thumbnail>();
        var large = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, 1200, 600);
        large.fill(0x4385bfff);
        try {
            thumbnails.add(new Xmpp.Xep.JingleContentThumbnails.Thumbnail() {
                data = new Bytes(Util.pixbuf_to_png_bytes(large)), media_type = "image/png"
            });
        } catch (Error e) { assert_false(true, e.message); return; }
        var preview = Util.get_thumbnail_preview(thumbnails);
        assert_false(preview == null, "valid thumbnails must still decode");
        if (preview != null) {
            fail_if_not_eq_int(320, preview.width);
            fail_if_not_eq_int(160, preview.height);
        }
        thumbnails.clear();
        thumbnails.add(thumbnail_from_base64("iVBORw0KGgoAAAANSUhEUgAAJxAAACcQCAIAAAA1LPVwAAAAAElEQVQ1rwYeAAAAAElFTkSuQmCC", "image/png"));
        assert_false(Util.get_thumbnail_preview(thumbnails) != null, "oversized PNG headers must be rejected even when decoding fails at close");
        thumbnails.clear();
        thumbnails.add(new Xmpp.Xep.JingleContentThumbnails.Thumbnail() {
            data = new Bytes(new uint8[262145]), media_type = "image/png"
        });
        assert_false(Util.get_thumbnail_preview(thumbnails) != null, "oversized encoded thumbnails must be skipped");
    }

    private void test_thumbnail_async() {
        var thumbnails = new ArrayList<Xmpp.Xep.JingleContentThumbnails.Thumbnail>();
        thumbnails.add(thumbnail_from_base64("iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAEElEQVR4nGP4z8AARAwoFABE0AX7pM/egAAAAABJRU5ErkJggg==", "image/png"));
        foreach (bool cancel in new bool[] { false, true }) {
            var cancellable = new Cancellable();
            if (cancel) cancellable.cancel();
            bool done = false;
            bool ui_ran = false;
            bool timed_out = false;
            var loop = new MainLoop();
            uint idle = Idle.add(() => { ui_ran = true; return Source.REMOVE; });
            uint timeout = Timeout.add_seconds(5, () => { timed_out = true; loop.quit(); return Source.REMOVE; });
            Util.get_thumbnail_preview_async.begin(thumbnails, cancellable, (obj, res) => {
                var result = Util.get_thumbnail_preview_async.end(res);
                assert_false(!ui_ran, "queued UI work must run while optional thumbnail decoding is pending");
                assert_false(cancel ? result != null : result == null, "cancelled jobs must not return a late preview");
                done = true;
                loop.quit();
            });
            if (!done) loop.run();
            if (!ui_ran) Source.remove(idle);
            if (!timed_out) Source.remove(timeout);
            assert_false(!done || timed_out, "bounded thumbnail decode must complete promptly");
        }
    }
}

}
