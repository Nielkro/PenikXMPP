#!/usr/bin/env python3

"""Guard MUC status-message rendering and nullable role updates."""

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


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} STATUS_POPULATOR", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    source = path.read_text(encoding="utf-8")
    role_handler = method_block(
        source,
        "private void on_role_updated(Account account, Jid occupant_jid, Xep.Muc.Role? role)",
    )
    role_guard_position = role_handler.find(
        "if (!should_show_muc_status_messages(current_conversation)) return;"
    )
    null_guard_position = role_handler.find("if (role == null) return;")
    switch_position = role_handler.find("switch (role)")
    if not role_handler or min(role_guard_position, null_guard_position, switch_position) < 0:
        print(f"{path}: nullable role handler or guard is missing", file=sys.stderr)
        return 1
    if role_guard_position > switch_position or null_guard_position > switch_position:
        print(f"{path}: role status is rendered before its guards", file=sys.stderr)
        return 1

    affiliation_handler = method_block(
        source,
        "private void on_affiliation_updated(Account account, Jid room_jid, Jid occupant_jid, Xep.Muc.Affiliation affiliation)",
    )
    affiliation_guard_position = affiliation_handler.find(
        "if (!should_show_muc_status_messages(current_conversation)) return;"
    )
    affiliation_switch_position = affiliation_handler.find("switch (affiliation)")
    if (
        not affiliation_handler
        or affiliation_guard_position < 0
        or affiliation_switch_position < 0
        or affiliation_guard_position > affiliation_switch_position
    ):
        print(f"{path}: affiliation status is rendered before its preference guard", file=sys.stderr)
        return 1

    for signature in (
        "private void on_self_removed(Account account, Jid room_jid, Xep.Muc.StatusCode code, string? reason)",
        "private void on_occupant_removed(Account account, Jid room_jid, Jid occupant_jid, Xep.Muc.StatusCode code)",
    ):
        removal_handler = method_block(source, signature)
        if "if (!is_muc_room_conversation(current_conversation)) return;" not in removal_handler:
            print(f"{path}: removal status is not scoped to the MUC room timeline", file=sys.stderr)
            return 1
        if "should_show_muc_status_messages" in removal_handler:
            print(f"{path}: important removal status must remain visible when routine status is off", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
