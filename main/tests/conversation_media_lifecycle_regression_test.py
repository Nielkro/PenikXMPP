#!/usr/bin/env python3

"""Guard bounded media previews and explicit signal-cycle cleanup."""

from pathlib import Path
import sys


def require(source: str, needle: str, path: Path) -> bool:
    if needle in source:
        return True
    print(f"{path}: missing media lifecycle marker: {needle}", file=sys.stderr)
    return False


def main() -> int:
    if len(sys.argv) != 4:
        print(
            f"usage: {Path(sys.argv[0]).name} "
            "REACTIONS_WIDGET AUDIO_PLAYER_WIDGET VIDEO_PLAYER_WIDGET",
            file=sys.stderr,
        )
        return 2

    reactions_path = Path(sys.argv[1])
    audio_path = Path(sys.argv[2])
    video_path = Path(sys.argv[3])
    reactions = reactions_path.read_text(encoding="utf-8")
    audio = audio_path.read_text(encoding="utf-8")
    video = video_path.read_text(encoding="utf-8")

    checks = [
        require(
            reactions,
            "reaction_clicked_handler_ids[reaction] = button.clicked.connect",
            reactions_path,
        ),
        require(
            reactions,
            "button.disconnect((!) handler_id);",
            reactions_path,
        ),
        require(reactions, "widget.cleanup();", reactions_path),
        require(reactions, "public override void dispose()", reactions_path),
        require(
            audio,
            "private ulong playback_error_handler_id = 0;",
            audio_path,
        ),
        require(
            audio,
            "playback_bridge).disconnect(playback_error_handler_id)",
            audio_path,
        ),
        require(
            video,
            'ElementFactory.make("videoscale", "thumb-vscale")',
            video_path,
        ),
        require(
            video,
            "width=(int)[1,320],height=(int)[1,240]",
            video_path,
        ),
        require(
            video,
            "pixel-aspect-ratio=(fraction)1/1",
            video_path,
        ),
        require(
            video,
            "playback_bridge).disconnect(playback_error_handler_id)",
            video_path,
        ),
    ]
    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
