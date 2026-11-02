#!/usr/bin/env python3
"""Offline checks for package-job deadlines; does not build or download anything."""

import argparse
from pathlib import Path
import re
import sys


WORKFLOW = Path(__file__).resolve().parent.parent / ".github/workflows/build.yml"
APPIMAGE_FINAL_GATE = "Runtime Matrix: final AppImage"
APPIMAGE_OFFLINE_GATE = "Offline AppImage gate: minimal Debian 13 desktop ABI"
# Run 264 took about 95 minutes before the final AppImage gates. Round that
# observed two-CPU build up, then leave separate room for upload and cleanup.
APPIMAGE_BUILD_MINUTES = 100
PACKAGE_FINISH_MINUTES = 10


def section(text, heading, boundary):
    matches = list(re.finditer(heading, text, re.MULTILINE))
    if len(matches) != 1:
        raise ValueError(f"expected exactly one section matching {heading!r}")
    tail = text[matches[0].end():]
    end = re.search(boundary, tail, re.MULTILINE)
    return tail[:end.start()] if end else tail


def timeout(text, indent, label):
    matches = re.findall(rf"^{indent}timeout-minutes: *([1-9][0-9]*) *(?:#.*)?$",
                         text, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError(f"{label} needs one explicit positive timeout-minutes")
    return int(matches[0])


def check(text):
    jobs = section(text, r"^jobs:\s*$", r"^[^\s#]")
    for name in ("build", "build-appimage", "build-flatpak"):
        job = section(jobs, rf"^  {name}:\s*$", r"^  [A-Za-z0-9_-]+:")
        limit = timeout(job, "    ", name)
        gate_minutes = sum(int(value) for value in re.findall(
            r"^        timeout-minutes: *([1-9][0-9]*) *(?:#.*)?$", job, re.MULTILINE))
        if limit <= gate_minutes:
            raise ValueError(f"{name}: job deadline leaves no time for building and upload")
        if name != "build-appimage":
            continue
        for gate, minimum in ((APPIMAGE_FINAL_GATE, 30), (APPIMAGE_OFFLINE_GATE, 20)):
            step = section(job, rf'^      - name: "{re.escape(gate)}"\s*$',
                           r"^      - ")
            if timeout(step, "        ", gate) < minimum:
                raise ValueError(f"{gate}: needs at least {minimum} minutes")
        required = APPIMAGE_BUILD_MINUTES + gate_minutes + PACKAGE_FINISH_MINUTES
        if limit < required:
            raise ValueError(f"build-appimage: {limit} minutes cannot cover the observed "
                             f"build, gate deadlines and upload; need at least {required}")


def self_test():
    fixture = f'''jobs:
  build:
    timeout-minutes: 120
    steps:
      - name: "Debian gate"
        timeout-minutes: 30
  build-appimage:
    timeout-minutes: 180
    steps:
      - name: "{APPIMAGE_FINAL_GATE}"
        timeout-minutes: 30
      - name: "{APPIMAGE_OFFLINE_GATE}"
        timeout-minutes: 20
  build-flatpak:
    timeout-minutes: 180
    steps:
      - name: "Flatpak gate"
        timeout-minutes: 45
'''
    check(fixture)
    invalid = (
        fixture.replace(f'"{APPIMAGE_FINAL_GATE}"\n        timeout-minutes: 30',
                        f'"{APPIMAGE_FINAL_GATE}"\n        timeout-minutes: 10'),
        fixture.replace("build-appimage:\n    timeout-minutes: 180",
                        "build-appimage:\n    timeout-minutes: 120"),
        fixture.replace("build-appimage:\n    timeout-minutes: 180",
                        "build-appimage:\n    timeout-minutes: 159"),
        fixture.replace("        timeout-minutes: 20", "        timeout-minutes: 60"),
        fixture.replace(f'      - name: "{APPIMAGE_FINAL_GATE}"',
                        '      - name: "Missing required gate"'),
        fixture.replace("build:\n    timeout-minutes: 120",
                        "build:\n    timeout-minutes: 30"),
    )
    for index, candidate in enumerate(invalid, start=1):
        try:
            check(candidate)
        except ValueError:
            continue
        raise AssertionError(f"unsafe deadline fixture {index} was accepted")
    print("OK: package deadline regression fixtures reject undersized step/job budgets")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true",
                        help="exercise offline regression fixtures only")
    parser.add_argument("workflow", nargs="?", type=Path, default=WORKFLOW)
    args = parser.parse_args()
    self_test()
    if args.self_test:
        return 0
    try:
        check(args.workflow.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("OK: package workflow deadlines leave room for the required AppImage gates")
    return 0


if __name__ == "__main__":
    sys.exit(main())
