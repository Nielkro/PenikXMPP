#!/usr/bin/env python3

"""Guard explicit ConversationSelectorRow lifecycle cleanup on every detach."""

from pathlib import Path
import sys


def method_block(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        return ""
    opening_brace = source.find("{", start + len(signature))
    if opening_brace < 0:
        return ""

    depth = 0
    for position in range(opening_brace, len(source)):
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0:
                return source[start : position + 1]
    return ""


def require(source: str, needle: str, path: Path, context: str) -> bool:
    if needle in source:
        return True
    print(f"{path}: missing {context}: {needle}", file=sys.stderr)
    return False


def main() -> int:
    if len(sys.argv) != 3:
        print(
            f"usage: {Path(sys.argv[0]).name} SELECTOR SELECTOR_ROW",
            file=sys.stderr,
        )
        return 2

    selector_path, row_path = map(Path, sys.argv[1:])
    selector_source = selector_path.read_text(encoding="utf-8")
    row_source = row_path.read_text(encoding="utf-8")

    cleanup_source = method_block(row_source, "internal void cleanup()")
    destructor_source = method_block(row_source, "~ConversationSelectorRow()")
    row_dispose_source = method_block(
        row_source, "public override void dispose()"
    )
    detach_source = method_block(
        selector_source,
        "private void detach_conversation_row(Conversation conversation,",
    )
    dispose_source = method_block(selector_source, "public override void dispose()")
    selector_init_source = method_block(
        selector_source,
        "public ConversationSelector init(StreamInteractor stream_interactor)",
    )
    context_menu_source = method_block(
        row_source, "private void show_context_menu(double x, double y)"
    )
    popover_cleanup_source = method_block(
        row_source, "private static void attach_context_popover_cleanup("
    )

    checks = [
        require(
            cleanup_source,
            "if (cleanup_complete) return;",
            row_path,
            "idempotent cleanup guard",
        ),
        require(
            cleanup_source,
            "cleanup_complete = true;",
            row_path,
            "cleanup state transition",
        ),
        require(
            cleanup_source,
            "SignalHandler.disconnect(cis, content_new_item_handler_id);",
            row_path,
            "ContentItemStore disconnect",
        ),
        require(
            cleanup_source,
            "SignalHandler.disconnect(cm, conversation_cleared_handler_id);",
            row_path,
            "ConversationManager disconnect",
        ),
        require(
            cleanup_source,
            "SignalHandler.disconnect(bm, block_changed_handler_id);",
            row_path,
            "BlockingManager disconnect",
        ),
        require(
            cleanup_source,
            'insert_action_group("row", null);',
            row_path,
            "context action cleanup",
        ),
        require(
            cleanup_source,
            "display_name_binding).unbind();",
            row_path,
            "display-name binding cleanup",
        ),
        require(
            cleanup_source,
            "avatar_model).cleanup();",
            row_path,
            "avatar model cleanup",
        ),
        require(
            cleanup_source,
            "picture.model = null;",
            row_path,
            "avatar widget model release",
        ),
        require(
            destructor_source,
            "cleanup();",
            row_path,
            "finalizer fallback",
        ),
        require(
            row_dispose_source,
            "cleanup();",
            row_path,
            "GObject disposal cleanup",
        ),
        require(
            detach_source,
            "conversation_row.cleanup();",
            selector_path,
            "row detach cleanup",
        ),
        require(
            dispose_source,
            "detach_conversation_row(conversation, conversation_row);",
            selector_path,
            "selector disposal cleanup",
        ),
        require(
            selector_init_source,
            "Dino.WeakTimeout.add_seconds(",
            selector_path,
            "weak periodic row updater",
        ),
        require(
            selector_init_source,
            "60, this, update_row_times",
            selector_path,
            "targetless periodic updater callback",
        ),
        require(
            dispose_source,
            "Source.remove(row_update_source_id);",
            selector_path,
            "periodic updater removal",
        ),
        require(
            context_menu_source,
            "attach_context_popover_cleanup(this, popover);",
            row_path,
            "isolated popover cleanup callback",
        ),
        require(
            popover_cleanup_source,
            "WeakRef row_weak = WeakRef(row);",
            row_path,
            "weak popover row callback",
        ),
        require(
            popover_cleanup_source,
            "WeakRef popover_weak = WeakRef(popover);",
            row_path,
            "weak popover callback",
        ),
    ]
    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
