#!/usr/bin/env python3
"""Count compiler diagnostics from an entire build, including failed phases.

Keep occurrences (a source may be compiled for several targets), but do not
count the decorated copies printed by build.sh's warning summary a second time.
Package-manager warnings and runtime application logs are not compiler output.
"""

import argparse
from collections import Counter
from pathlib import Path
import re


ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
DIAGNOSTIC = re.compile(
    r"^(?:.+:\d+(?::\d+|\.\d+(?:-\d+\.\d+)?)?:|"
    r"(?:.*[/\\])?(?:cc1(?:plus)?|gcc|g\+\+|clang(?:\+\+)?|ld)(?:\.exe)?:)\s+warning:",
    re.IGNORECASE,
)


def warnings(text):
    for line in text.splitlines():
        line = ANSI.sub("", line)
        if line.lstrip().startswith("⚠"):
            continue
        if DIAGNOSTIC.match(line):
            yield line


def extract(log_path, detail_path):
    entries = list(warnings(log_path.read_text(encoding="utf-8", errors="replace")))
    detail_path.write_text("".join(line + "\n" for line in entries), encoding="utf-8")
    return entries


def report(log_path):
    detail_path = log_path.with_suffix(".warnings.txt")
    entries = extract(log_path, detail_path)
    counts = Counter()
    for entry in entries:
        match = re.search(r"\[(-W[^\]]+)\]$", entry)
        counts[match[1] if match else "other"] += 1
    print(f"Compiler warnings (whole Windows build): {len(entries)}")
    for category, count in sorted(counts.items()):
        print(f"  {category}: {count}")
    print(f"WINDOWS_COMPILER_WARNING_COUNT={len(entries)}")
    print(f"BUILD_WARNINGS={detail_path}")


def self_test():
    sample = "\n".join([
        "src/demo.c:20:4: warning: incompatible pointer [-Wincompatible-pointer-types]",
        "C:/Source with spaces/demo.cpp:3: warning: unused [-Wunused-function]",
        "main.vala:12.4-12.19: warning: unused method",
        "\x1b[33mfile.h:2:1: warning: header diagnostic\x1b[0m",
        "cc1.exe: warning: driver diagnostic",
        "C:/mingw64/bin/ld.exe: warning: linker diagnostic",
        "  ⚠  src/demo.c:20:4: warning: summary copy [-Wincompatible-pointer-types]",
        "warning: package is up to date -- reinstalling",
        "OMEMO-WARNING **: runtime diagnostic",
        "file.c:2:1: error: failure",
        "Warnings: 0 — clean build!",
    ])
    assert len(list(warnings(sample))) == 6
    assert list(warnings("")) == []
    print("OK: whole-build warning parser")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, nargs="?")
    parser.add_argument("--output", type=Path, help="only extract diagnostics to this file")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.log is not None and args.output is not None:
        extract(args.log, args.output)
    elif args.log is not None:
        report(args.log)
    else:
        parser.error("provide a log file or --self-test")
