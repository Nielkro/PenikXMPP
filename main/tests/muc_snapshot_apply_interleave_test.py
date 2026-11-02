#!/usr/bin/env python3

"""Guard sliced MUC snapshot apply against live-batch restart churn."""

from pathlib import Path
import sys


def method_body(source: str, signature: str, path: Path) -> str:
    start = source.find(signature)
    if start < 0:
        raise AssertionError(f"{path}: missing method: {signature}")
    opening = source.find("{", start + len(signature))
    if opening < 0:
        raise AssertionError(f"{path}: method has no body: {signature}")

    depth = 0
    for position in range(opening, len(source)):
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1 : position]
    raise AssertionError(f"{path}: unterminated method: {signature}")


def require_order(body: str, *needles: str) -> None:
    position = -1
    for needle in needles:
        next_position = body.find(needle, position + 1)
        if next_position < 0:
            raise AssertionError(f"missing or out-of-order marker: {needle}")
        position = next_position


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} OCCUPANT_LIST", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    source = path.read_text(encoding="utf-8")
    try:
        if "private bool room_snapshot_followup_pending = false;" not in source:
            raise AssertionError("missing coalesced full-snapshot follow-up")

        live_batch = method_body(
            source,
            "private void on_room_occupants_changed_batch(Account account, Jid room,",
            path,
        )
        require_order(
            live_batch,
            "if (snapshot_apply_source != 0 && pending_room_snapshot != null)",
            "room_snapshot_followup_pending = true;",
            "return;",
            "if (cache.stable_occupants == null ||",
        )
        if "waiting_for_initial_snapshot || snapshot_apply_source != 0" in live_batch:
            raise AssertionError("live batches still restart an active sliced apply")

        schedule = method_body(
            source,
            "private void schedule_room_snapshot_apply(MucRoomDelta delta)",
            path,
        )
        require_order(
            schedule,
            "if (snapshot_apply_source != 0 && pending_room_snapshot != null)",
            "room_snapshot_followup_pending = true;",
            "return;",
            "cancel_room_snapshot_apply();",
        )

        process = method_body(
            source,
            "private bool process_room_snapshot_apply(uint generation)",
            path,
        )
        require_order(
            process,
            "bool committed = commit_room_snapshot(delta);",
            "clear_room_snapshot_apply_state();",
            "continue_with_room_snapshot_followup()",
        )

        followup = method_body(
            source,
            "private bool continue_with_room_snapshot_followup()",
            path,
        )
        require_order(
            followup,
            "bool has_followup = room_snapshot_followup_pending;",
            "room_snapshot_followup_pending = false;",
            "get_room_occupants_snapshot(",
            "schedule_room_snapshot_apply((!) current);",
        )

        request = method_body(
            source,
            "private void request_current_room_snapshot_followup()",
            path,
        )
        require_order(
            request,
            "get_room_occupants_snapshot(",
            "((!) current) != (!) pending_room_snapshot",
            "room_snapshot_followup_pending = true;",
        )

        cancel = method_body(
            source,
            "private void cancel_room_snapshot_apply()",
            path,
        )
        require_order(
            cancel,
            "clear_room_snapshot_apply_state();",
            "room_snapshot_followup_pending = false;",
        )
    except AssertionError as error:
        print(f"{path}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
