using Gtk;
using Dino.Ui.ConversationSummary;

namespace Dino.Ui.Test {

class MessageActionTargetRuntimeTest : Gee.TestCase {
    public MessageActionTargetRuntimeTest() {
        base("MessageActionTargetRuntime");
        add_test("embedded_reply_quote_never_owns_row_actions",
            test_embedded_reply_quote_never_owns_row_actions);
        add_test("reply_body_resolves_its_own_row",
            test_reply_body_resolves_its_own_row);
        add_test("reply_header_quote_and_body_have_unambiguous_targets",
            test_reply_header_quote_and_body_have_unambiguous_targets);
        add_test("destructive_confirmation_identifies_target",
            test_destructive_confirmation_identifies_target);
        add_test("reply_batch_requires_complete_global_preflight",
            test_reply_batch_requires_complete_global_preflight);
        add_test("reply_batch_result_is_presented_honestly",
            test_reply_batch_result_is_presented_honestly);
    }

    private void test_embedded_reply_quote_never_owns_row_actions() {
        var main = new Box(Orientation.VERTICAL, 0);
        var reply_row = new Box(Orientation.VERTICAL, 0);
        var quote = new Box(Orientation.VERTICAL, 0);
        var quote_text = new Label("original message");
        quote.add_css_class("dino-quote");
        quote.append(quote_text);
        reply_row.append(quote);
        main.append(reply_row);

        fail_if(MessageActionTarget.find_row_for_pointer(main, quote_text) != null,
            "the embedded original must not expose actions for the reply row");
        fail_if(MessageActionTarget.find_row_for_pointer(main, quote) != null,
            "the quote root itself must not expose actions for the reply row");

        main.remove(reply_row);
    }

    private void test_reply_body_resolves_its_own_row() {
        var main = new Box(Orientation.VERTICAL, 0);
        var reply_row = new Box(Orientation.VERTICAL, 0);
        var body_wrapper = new Box(Orientation.VERTICAL, 0);
        var body = new Label("reply body");
        body_wrapper.append(body);
        reply_row.append(body_wrapper);
        main.append(reply_row);

        fail_if(MessageActionTarget.find_row_for_pointer(main, body) != reply_row,
            "the actual reply body must keep the reply row actions");

        main.remove(reply_row);
    }

    private void test_reply_header_quote_and_body_have_unambiguous_targets() {
        var main = new Box(Orientation.VERTICAL, 0);
        var reply_row = new Box(Orientation.VERTICAL, 0);
        var header = new Label("invite");
        var quote = new Box(Orientation.VERTICAL, 0);
        var quoted_text = new Label("DinoX: hallo");
        var body = new Label("hoi");
        quote.add_css_class("dino-quote");
        quote.append(quoted_text);
        reply_row.append(header);
        reply_row.append(quote);
        reply_row.append(body);
        main.append(reply_row);

        fail_if(MessageActionTarget.find_row_for_pointer(main, header) !=
                reply_row,
            "the reply header must target the reply row");
        fail_if(MessageActionTarget.find_row_for_pointer(main, quoted_text) !=
                null,
            "moving from the reply header into its quote must clear actions");
        fail_if(MessageActionTarget.find_row_for_pointer(main, body) !=
                reply_row,
            "the reply body must target the reply row again");

        main.remove(reply_row);
    }

    private void test_destructive_confirmation_identifies_target() {
        string c1_next_line = ((unichar) 0x85).to_string();
        string detail = MessageActionTarget.format_confirmation_detail(
            "Remove this message?", "in\u202Evite\u202C\nspoofed",
            "hoi\u2028second" + c1_next_line + " line");
        fail_if(detail !=
                "Remove this message?\n\nin vite spoofed:\nhoi second line",
            "the confirmation must neutralize multiline and bidi spoofing");

        string long_preview = string.nfill(118, 'a') + "äää";
        string truncated = MessageActionTarget.format_confirmation_detail(
            "Remove this message?", "invite", long_preview);
        string rendered_preview = truncated.substring(
            truncated.last_index_of("\n") + 1);
        fail_if(!rendered_preview.validate(),
            "truncation must preserve valid UTF-8");
        fail_if(rendered_preview.char_count() != 120 ||
                !rendered_preview.has_suffix("…"),
            "the target preview must remain short enough for the dialog");

        fail_if(MessageActionTarget.format_target_label(
                    "in\u202Evite\u202C\nspoofed") != "in vite spoofed:",
            "the floating toolbar must show the same single-line target");
    }

    private void test_reply_batch_requires_complete_global_preflight() {
        fail_if(!MessageActionTarget.global_delete_response_enabled(
                    false, true, false),
            "an unsuitable reply must not disable root-only deletion");
        fail_if(MessageActionTarget.global_delete_response_enabled(
                    true, true, false),
            "including replies must fail closed when one item is unsuitable");
        fail_if(!MessageActionTarget.global_delete_response_enabled(
                    true, true, true),
            "including replies must be enabled after a complete preflight");
        fail_if(MessageActionTarget.global_delete_response_enabled(
                    false, false, false),
            "a stale root must disable even root-only global deletion");

        string singular = MessageActionTarget.format_reply_inclusion_label(1);
        string plural = MessageActionTarget.format_reply_inclusion_label(100);
        fail_if(!singular.validate() || singular !=
                "Also delete 1 known reply in full",
            "the singular option must identify a complete reply message");
        fail_if(!plural.validate() || plural !=
                "Also delete 100 known replies in full",
            "large counts must still identify complete reply messages");
    }

    private void test_reply_batch_result_is_presented_honestly() {
        fail_if(MessageActionTarget.classify_batch_result(true, false) !=
                MessageDeletionBatchPresentation.SUCCESS,
            "a complete backend result must be presented as success");
        fail_if(MessageActionTarget.classify_batch_result(false, true) !=
                MessageDeletionBatchPresentation.PARTIAL,
            "partial protocol progress must be presented as partial even when no complete item succeeded");
        fail_if(MessageActionTarget.classify_batch_result(false, false) !=
                MessageDeletionBatchPresentation.FAILURE,
            "zero protocol progress must be presented as failure");
    }
}

}
