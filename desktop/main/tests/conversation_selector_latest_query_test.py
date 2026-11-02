#!/usr/bin/env python3

"""Guard the sidebar row's single latest-content query during initialization."""

from pathlib import Path
import re
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} CONVERSATION_SELECTOR_ROW", file=sys.stderr)
        return 2

    source_path = Path(sys.argv[1])
    source = source_path.read_text(encoding="utf-8")
    latest_calls = re.findall(r"\.get_latest\s*\(\s*conversation\s*\)", source)

    if len(latest_calls) != 1:
        print(
            f"{source_path}: expected exactly one get_latest(conversation) call, "
            f"found {len(latest_calls)}",
            file=sys.stderr,
        )
        return 1

    if len(re.findall(r"\bcontent_item_received\s*\(\s*\)\s*;", source)) != 1:
        print(
            f"{source_path}: expected one initial content_item_received() call",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
