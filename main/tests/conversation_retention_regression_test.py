#!/usr/bin/env python3

"""Guard conversation row ownership and bounded content/media retention."""

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


def require(source: str, needle: str, path: Path) -> bool:
    if needle in source:
        return True
    print(f"{path}: missing retention marker: {needle}", file=sys.stderr)
    return False


def forbid(source: str, needle: str, path: Path) -> bool:
    if needle not in source:
        return True
    print(f"{path}: forbidden ownership marker: {needle}", file=sys.stderr)
    return False


def main() -> int:
    if len(sys.argv) != 5:
        print(
            f"usage: {Path(sys.argv[0]).name} "
            "CONVERSATION_VIEW CONVERSATION_ITEM_SKELETON "
            "MESSAGE_WIDGET FILE_IMAGE_WIDGET",
            file=sys.stderr,
        )
        return 2

    view_path = Path(sys.argv[1])
    skeleton_path = Path(sys.argv[2])
    message_path = Path(sys.argv[3])
    file_image_path = Path(sys.argv[4])
    view_source = view_path.read_text(encoding="utf-8")
    skeleton_source = skeleton_path.read_text(encoding="utf-8")
    message_source = message_path.read_text(encoding="utf-8")
    file_image_source = file_image_path.read_text(encoding="utf-8")

    insert_item = method_block(
        view_source,
        "public void insert_item(Plugins.MetaConversationItem item)",
    )
    display_latest = method_block(
        view_source,
        "private void display_latest(",
    )
    prune_around = method_block(
        view_source,
        "private void prune_content_items_around(ContentMetaItem inserted_item)",
    )
    prune_status = method_block(
        view_source,
        "private void prune_oldest_status_items()",
    )
    remove_item = method_block(
        view_source,
        "private void remove_item(Plugins.MetaConversationItem item)",
    )
    clear = method_block(view_source, "private void clear()")
    clear_message_action_target = method_block(
        view_source,
        "private void clear_message_action_target()",
    )
    action_button_clicked = method_block(
        view_source,
        "private void on_action_button_clicked(",
    )
    message_dispose = method_block(
        message_source,
        "public override void dispose()",
    )
    cleanup_edit_mode = method_block(
        message_source,
        "private void cleanup_edit_mode()",
    )
    edit_mode_changed = method_block(
        message_source,
        "private void on_in_edit_mode_changed()",
    )
    claim_edit_mode_leave = method_block(
        message_source,
        "private bool claim_edit_mode_leave(",
    )
    skeleton_dispose = method_block(
        skeleton_source,
        "public override void dispose()",
    )
    set_widget = method_block(
        skeleton_source,
        "public void set_widget(Object object, Plugins.WidgetType type, int priority)",
    )
    load_from_thumbnail = method_block(
        file_image_source,
        "public async void load_from_thumbnail(FileTransfer file_transfer)",
    )

    checks = [
        bool(insert_item)
        and require(insert_item, "prune_oldest_items();", view_path),
        bool(insert_item)
        and require(
            insert_item,
            "prune_content_items_around((!) content_item);",
            view_path,
        ),
        bool(insert_item)
        and require(insert_item, "if (item is MetaStatusItem)", view_path),
        bool(insert_item)
        and require(insert_item, "prune_oldest_status_items();", view_path),
        bool(display_latest)
        and require(display_latest, "prune_oldest_items();", view_path),
        require(view_source, "private const int MAX_CONTENT_ITEMS = 200;", view_path),
        require(view_source, "private const int MAX_STATUS_ITEMS = 200;", view_path),
        bool(prune_around)
        and require(
            prune_around,
            "while (content_items.size > MAX_CONTENT_ITEMS)",
            view_path,
        ),
        bool(prune_status)
        and require(prune_status, "if (item is MetaStatusItem)", view_path),
        bool(prune_status)
        and require(
            prune_status,
            "while (status_count > MAX_STATUS_ITEMS)",
            view_path,
        ),
        bool(remove_item)
        and require(
            remove_item,
            "Plugins.MetaConversationItem? lower_item = meta_items.lower(item);",
            view_path,
        ),
        bool(remove_item)
        and require(
            remove_item,
            "Plugins.MetaConversationItem? upper_item = meta_items.higher(item);",
            view_path,
        ),
        bool(remove_item)
        and require(
            remove_item,
            "upper_skeleton.show_skeleton = lower_item == null",
            view_path,
        ),
        require(
            message_source,
            "public weak Plugins.ConversationItemWidgetInterface outer",
            message_path,
        ),
        bool(message_dispose)
        and require(message_dispose, "outer = null;", message_path),
        bool(message_dispose)
        and require(message_dispose, "message_item = null;", message_path),
        bool(message_dispose)
        and require(message_dispose, "cleanup_edit_mode();", message_path),
        bool(cleanup_edit_mode)
        and require(
            cleanup_edit_mode,
            "edit_mode).disconnect(edit_send_handler_id);",
            message_path,
        ),
        bool(cleanup_edit_mode)
        and require(
            cleanup_edit_mode,
            "controller).unset_conversation();",
            message_path,
        ),
        bool(cleanup_edit_mode)
        and require(cleanup_edit_mode, "edit_mode = null;", message_path),
        bool(cleanup_edit_mode)
        and require(cleanup_edit_mode, "controller = null;", message_path),
        bool(edit_mode_changed)
        and forbid(
            edit_mode_changed,
            "outer.set_widget(label, Plugins.WidgetType.GTK4, 2);",
            message_path,
        ),
        bool(claim_edit_mode_leave)
        and require(claim_edit_mode_leave, "edit_leave_source_id = Idle.add", message_path),
        bool(claim_edit_mode_leave)
        and require(
            claim_edit_mode_leave,
            "current_outer).set_widget(label,",
            message_path,
        ),
        bool(claim_edit_mode_leave)
        and require(claim_edit_mode_leave, "cleanup_edit_mode();", message_path),
        bool(cleanup_edit_mode)
        and require(cleanup_edit_mode, "Source.remove(edit_leave_source_id);", message_path),
        bool(skeleton_dispose)
        and require(skeleton_dispose, "item = null;", skeleton_path),
        bool(skeleton_dispose)
        and require(skeleton_dispose, "content_meta_item = null;", skeleton_path),
        bool(skeleton_dispose)
        and require(skeleton_dispose, "content_widget.dispose();", skeleton_path),
        bool(message_dispose)
        and forbid(message_dispose, "label.dispose();", message_path),
        bool(message_dispose)
        and forbid(message_dispose, "label.unparent();", message_path),
        bool(set_widget)
        and require(
            set_widget,
            "if (content_widget.get_parent() != null) content_widget.unparent();",
            skeleton_path,
        ),
        bool(clear)
        and require(clear, "clear_message_action_target();", view_path),
        bool(clear_message_action_target)
        and require(
            clear_message_action_target,
            "current_meta_item = null;",
            view_path,
        ),
        bool(clear_message_action_target)
        and require(
            clear_message_action_target,
            "message_actions = null;",
            view_path,
        ),
        bool(action_button_clicked)
        and require(
            action_button_clicked,
            "clear_message_action_target();",
            view_path,
        ),
        require(
            view_source,
            ".received_correction.connect(on_item_corrected);",
            view_path,
        ),
        bool(load_from_thumbnail)
        and require(
            load_from_thumbnail,
            "create_image_picture(file_transfer, pixbuf.width, pixbuf.height)",
            file_image_path,
        ),
        bool(load_from_thumbnail)
        and "pixbuf.scale_simple" not in load_from_thumbnail,
    ]
    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
