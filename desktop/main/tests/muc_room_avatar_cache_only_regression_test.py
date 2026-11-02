#!/usr/bin/env python3

"""Guard XEP-0486 pre-join discovery from leaking into MUC UI hot paths."""

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


def require(source: str, marker: str, path: Path) -> None:
    if marker not in source:
        raise AssertionError(f"{path}: missing marker: {marker}")


def forbid(source: str, marker: str, path: Path) -> None:
    if marker in source:
        raise AssertionError(f"{path}: forbidden hot-path marker: {marker}")


def main() -> int:
    if len(sys.argv) != 5:
        print(
            f"usage: {Path(sys.argv[0]).name} "
            "CONFERENCE_LIST AVATAR_WORKER XEP0486_MODULE MUC_MANAGER",
            file=sys.stderr,
        )
        return 2

    conference_path, worker_path, protocol_path, muc_manager_path = map(
        Path, sys.argv[1:]
    )
    conference_source = conference_path.read_text(encoding="utf-8")
    worker_source = worker_path.read_text(encoding="utf-8")
    protocol_source = protocol_path.read_text(encoding="utf-8")
    muc_manager_source = muc_manager_path.read_text(encoding="utf-8")
    try:
        row_start = conference_source.find("internal class ConferenceListRow")
        if row_start < 0:
            raise AssertionError(f"{conference_path}: ConferenceListRow missing")
        row_source = conference_source[row_start:]

        require(
            row_source,
            "get_avatar_bytes_from_local_cache_async",
            conference_path,
        )
        require(row_source, "observe_avatar(account, bare_jid", conference_path)
        require(row_source, "avatar_observer).unsubscribe()", conference_path)
        require(row_source, "public override void dispose()", conference_path)
        require(row_source, "deactivate_conference_row();", conference_path)
        for marker in (
            "AvatarReadPolicy.NETWORK_ALLOWED",
            "get_avatar_bytes(account",
            "fetch_and_store_for_jid",
            "MucRoomAvatarManager",
            "request_info(",
            "send_iq",
        ):
            forbid(row_source, marker, conference_path)

        queue_body = method_body(
            worker_source,
            "private void queue_discovery(Account account, Jid room,",
            worker_path,
        )
        schedule_body = method_body(
            worker_source,
            "private void schedule_drain(uint delay_ms)",
            worker_path,
        )
        drain_body = method_body(
            worker_source,
            "private void drain()",
            worker_path,
        )
        require(worker_source, "private const int MAX_QUEUED_ROOMS = 128;", worker_path)
        require(worker_source, "private const uint INITIAL_DELAY_MS = 5000;", worker_path)
        require(worker_source, "stream_interactor.stream_negotiated.connect(on_stream_ready);", worker_path)
        require(worker_source, "stream_interactor.stream_resumed.connect(on_stream_ready);", worker_path)
        require(worker_source, "Idle.add_full(Priority.LOW", worker_path)
        require(worker_source, "!stream.negotiation_complete", worker_path)
        require(queue_body, "queued.size >= MAX_QUEUED_ROOMS", worker_path)
        require(schedule_body, "Timeout.add_full(Priority.LOW", worker_path)
        require(schedule_body, "active_work != null", worker_path)
        require(drain_body, "active_work = work;", worker_path)
        require(drain_body, "process.begin(work", worker_path)
        if drain_body.count("process.begin(work") != 1:
            raise AssertionError(
                f"{worker_path}: discovery drain must start exactly one async operation"
            )

        fetch_body = method_body(
            protocol_source,
            "public static async FetchedRoomAvatar? fetch_advertised_avatar(",
            protocol_path,
        )
        decode_body = method_body(
            protocol_source,
            "private static async FetchedRoomAvatar? select_advertised_avatar_async(",
            protocol_path,
        )
        require(fetch_body, "send_iq_async(stream, request, Priority.LOW", protocol_path)
        require(fetch_body, "yield select_advertised_avatar_async", protocol_path)
        require(decode_body, "task.run_in_thread", protocol_path)
        require(protocol_source, "if (from == null) return false;", protocol_path)
        require(protocol_source, "MAX_ADVERTISED_HASHES = 8", protocol_path)
        require(protocol_source, "MAX_VCARD_PHOTOS = 8", protocol_path)

        require(
            muc_manager_source,
            "bookmarks_updated(account,\n                filter_manually_removed_conferences",
            muc_manager_path,
        )
    except AssertionError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
