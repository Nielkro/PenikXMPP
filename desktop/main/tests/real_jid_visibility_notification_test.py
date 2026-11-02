#!/usr/bin/env python3

"""Guard the join-scoped non-anonymous-room warning lifecycle."""

from pathlib import Path
import sys
from typing import Optional, Sequence


def require(source: str, needle: str, path: Path) -> bool:
    if needle in source:
        return True
    print(f"{path}: missing real-JID warning marker: {needle}", file=sys.stderr)
    return False


def forbid(source: str, needle: str, path: Path) -> bool:
    if needle not in source:
        return True
    print(f"{path}: forbidden real-JID warning marker: {needle}", file=sys.stderr)
    return False


def block_after(source: str, marker: str, path: Path) -> Optional[str]:
    marker_pos = source.find(marker)
    block_start = source.find("{", marker_pos + len(marker))
    if marker_pos < 0 or block_start < 0:
        print(f"{path}: missing real-JID warning block: {marker}", file=sys.stderr)
        return None

    depth = 0
    for pos in range(block_start, len(source)):
        if source[pos] == "{":
            depth += 1
        elif source[pos] == "}":
            depth -= 1
            if depth == 0:
                return source[block_start + 1 : pos]

    print(f"{path}: unterminated real-JID warning block: {marker}", file=sys.stderr)
    return None


def require_order(
    source: str,
    markers: Sequence[str],
    path: Path,
    context: str,
) -> bool:
    cursor = -1
    for marker in markers:
        cursor = source.find(marker, cursor + 1)
        if cursor < 0:
            print(
                f"{path}: missing or out-of-order {marker!r} in {context}",
                file=sys.stderr,
            )
            return False
    return True


def main() -> int:
    if len(sys.argv) != 3:
        print(
            f"usage: {Path(sys.argv[0]).name} NOTIFICATION CONVERSATION_VIEW",
            file=sys.stderr,
        )
        return 2

    notification_path, view_path = map(Path, sys.argv[1:])
    notification = notification_path.read_text(encoding="utf-8")
    view = view_path.read_text(encoding="utf-8")

    block_markers = {
        "visibility": "private void on_visibility_changed(",
        "join_started": "private void on_join_started(",
        "left": "private void on_left(",
        "key": "private static string room_key(",
        "init": "public void init(",
        "rebuild": "private void rebuild()",
        "close": "close_button.clicked.connect(() =>",
        "dispose": "public override void dispose()",
    }
    blocks = {
        name: block_after(notification, marker, notification_path)
        for name, marker in block_markers.items()
    }
    if any(block is None for block in blocks.values()):
        return 1

    checks = [
        require(
            notification,
            "public class RealJidVisibilityNotification : Object",
            notification_path,
        ),
        require(
            notification,
            "manager.room_real_jid_visibility_changed.connect(",
            notification_path,
        ),
        require(
            notification,
            "manager.room_initial_sync_started.connect(",
            notification_path,
        ),
        require(notification, "on_join_started);", notification_path),
        forbid(notification, "manager.joined.connect(", notification_path),
        require(
            notification,
            "manager.left_signal.connect(on_left);",
            notification_path,
        ),
        require(
            notification,
            'tooltip_text = _("Close")',
            notification_path,
        ),
        require(notification, '"window-close-symbolic"', notification_path),
        require(
            notification,
            'AccessibleProperty.LABEL, _("Close"), -1',
            notification_path,
        ),
        require_order(
            blocks["key"] or "",
            ("account.id.to_string()", "room_jid.bare_jid.to_string()"),
            notification_path,
            "account and bare-room key",
        ),
        forbid(blocks["init"] or "", "dismissed_room_keys", notification_path),
        require_order(
            blocks["visibility"] or "",
            (
                "dismissed_room_keys.remove(room_key(account, room_jid));",
                "if (!is_current_room(account, room_jid)) return;",
                "visibility == Xmpp.Xep.Muc.RealJidVisibility.ANYONE",
                "rebuild();",
                "remove_current_notification();",
            ),
            notification_path,
            "visibility reset and redraw",
        ),
        require_order(
            blocks["join_started"] or "",
            (
                "dismissed_room_keys.remove(room_key(account, room_jid));",
                "is_current_room(account, room_jid)",
                "rebuild();",
            ),
            notification_path,
            "network join reset",
        ),
        require_order(
            blocks["left"] or "",
            (
                "dismissed_room_keys.remove(room_key(account, room_jid));",
                "is_current_room(account, room_jid)",
                "remove_current_notification();",
            ),
            notification_path,
            "leave reset",
        ),
        require_order(
            blocks["rebuild"] or "",
            (
                "Xmpp.Xep.Muc.RealJidVisibility.ANYONE",
                "dismissed_room_keys.contains(warning_key)",
                "new Box(Orientation.HORIZONTAL, 8)",
            ),
            notification_path,
            "dismissed banner suppression",
        ),
        require_order(
            blocks["close"] or "",
            (
                "current_notification != container",
                "is_current_room(warned_account, warned_room)",
                "dismissed_room_keys.add(warning_key);",
                "remove_current_notification();",
            ),
            notification_path,
            "room-bound close action",
        ),
        require_order(
            blocks["dispose"] or "",
            (
                "visibility_changed_handler_id",
                "join_started_handler_id",
                "left_handler_id",
                "dismissed_room_keys.clear();",
            ),
            notification_path,
            "signal cleanup",
        ),
        forbid(notification, "muc#roomconfig_whois", notification_path),
        forbid(notification, "Database", notification_path),
        forbid(notification, "account_settings", notification_path),
        forbid(notification, "conversation_settings", notification_path),
        require(
            view,
            "new RealJidVisibilityNotification(stream_interactor);",
            view_path,
        ),
        require(
            view,
            "real_jid_visibility_notification.init(conversation, this);",
            view_path,
        ),
        require(
            view,
            "real_jid_visibility_notification.dispose();",
            view_path,
        ),
    ]
    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
