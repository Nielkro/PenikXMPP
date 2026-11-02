/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gtk;

namespace Dino.Ui.ConversationSummary {

internal enum MessageDeletionBatchPresentation {
    SUCCESS,
    PARTIAL,
    FAILURE
}

public class MessageActionTarget : Object {
    private const string EMBEDDED_QUOTE_CSS_CLASS = "dino-quote";
    private const int TARGET_NAME_MAX_CHARS = 48;
    private const int CONTENT_PREVIEW_MAX_CHARS = 120;

    private static string single_line(string? text, int max_chars) {
        string valid = (text ?? "").make_valid();
        var normalized = new StringBuilder();
        bool pending_space = false;
        int byte_index = 0;
        unichar character;
        while (valid.get_next_char(ref byte_index, out character)) {
            UnicodeType type = character.type();
            bool unsafe_format = type == UnicodeType.CONTROL ||
                type == UnicodeType.FORMAT ||
                type == UnicodeType.LINE_SEPARATOR ||
                type == UnicodeType.PARAGRAPH_SEPARATOR;
            if (unsafe_format || character.isspace()) {
                if (normalized.len > 0) pending_space = true;
                continue;
            }
            if (pending_space) {
                normalized.append_c(' ');
                pending_space = false;
            }
            normalized.append_unichar(character);
        }

        string safe = normalized.str;
        if (safe.char_count() <= max_chars) return safe;
        return safe.substring(0, safe.index_of_nth_char(max_chars - 1)) + "…";
    }

    /** Visible owner prefix for the floating row-action toolbar. */
    internal static string format_target_label(string? display_name) {
        string safe_name = single_line(display_name, TARGET_NAME_MAX_CHARS);
        return safe_name == "" ? "" : safe_name + ":";
    }

    /**
     * Add an unambiguous, bounded target preview to a destructive confirmation.
     * The prompt remains translated separately; participant names and message
     * bodies are user data and therefore stay plain text.
     */
    internal static string format_confirmation_detail(string prompt,
            string? display_name, string? content_preview) {
        string safe_name = single_line(display_name, TARGET_NAME_MAX_CHARS);
        string safe_preview = single_line(content_preview,
            CONTENT_PREVIEW_MAX_CHARS);
        if (safe_name == "" && safe_preview == "") return prompt;

        string target = safe_name;
        if (safe_preview != "") {
            target += (target == "" ? "" : ":\n") + safe_preview;
        }
        return prompt + "\n\n" + target;
    }

    /** Label for the optional direct-reply snapshot in the delete dialog. */
    internal static string format_reply_inclusion_label(int reply_count) {
        return ngettext("Also delete %d known reply in full",
            "Also delete %d known replies in full",
            reply_count).printf(reply_count);
    }

    /**
     * Keep root-only deletion available independently from an incomplete
     * reply snapshot. Once replies are selected, every item must pass the
     * global-delete preflight before the destructive response is enabled.
     */
    internal static bool global_delete_response_enabled(
            bool include_replies, bool root_can_delete_for_everyone,
            bool all_items_can_delete_for_everyone) {
        return include_replies
            ? all_items_can_delete_for_everyone
            : root_can_delete_for_everyone;
    }

    /** Stable presentation bucket for the detailed backend batch result. */
    internal static MessageDeletionBatchPresentation classify_batch_result(
            bool success, bool partial_success) {
        if (success) return MessageDeletionBatchPresentation.SUCCESS;
        if (partial_success) {
            return MessageDeletionBatchPresentation.PARTIAL;
        }
        return MessageDeletionBatchPresentation.FAILURE;
    }

    /**
     * Resolve the direct conversation-row child under the pointer.
     *
     * A rendered reply quote belongs to the reply row in the GTK hierarchy,
     * but visually represents another message. Never expose the reply row's
     * actions while the pointer is over that embedded reference: clicking the
     * quote remains responsible for jumping to the referenced message.
     */
    internal static Widget? find_row_for_pointer(Widget main, Widget? picked) {
        Widget? candidate = picked;
        while (candidate != null && candidate != main) {
            if (((!) candidate).has_css_class(EMBEDDED_QUOTE_CSS_CLASS)) {
                return null;
            }

            Widget? parent = ((!) candidate).get_parent();
            if (parent == main) {
                return candidate;
            }
            candidate = parent;
        }
        return null;
    }
}

}
