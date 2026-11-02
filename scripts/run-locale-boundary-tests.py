#!/usr/bin/env python3
"""Run production boundary tests with a verified non-default system locale.

No account, desktop setting or system locale installation is changed. On Linux,
missing locales may be generated privately from the installed locale sources.
Meson reports an explicit skip (77) when the required locale is unavailable.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from language_test_support import native_locale, REGIONS


def main():
    # The test changes LC_ALL deliberately; the report must still be writable
    # when GLib emits Unicode diagnostics on a Windows console or redirected pipe.
    sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
    sys.stderr.reconfigure(encoding="utf-8", errors="backslashreplace")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--locale", required=True, choices=tuple(REGIONS))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a test command is required after --")

    with native_locale(args.locale) as env, tempfile.TemporaryDirectory(prefix="dinox-language-profile-") as profile:
        if env is None:
            print(f"SKIP: required {args.locale} system locale is unavailable", flush=True)
            return 77
        # The full-widget fixture must never open the user's normal profile.
        env.update(XDG_DATA_HOME=str(Path(profile) / "data"),
                   XDG_CACHE_HOME=str(Path(profile) / "cache"),
                   XDG_CONFIG_HOME=str(Path(profile) / "config"))
        if any(Path(item).name == "xvfb-run" for item in command):
            env.update(GDK_BACKEND="x11", GTK_IM_MODULE="gtk-im-context-simple",
                       DINOX_TEST_NATIVE_KEYS="1", GSK_RENDERER="cairo")
        # GLib accepts a non-existent -p filter and exits successfully with
        # 1..0. Require actual matching test results, including on older builds.
        requested = [command[i + 1] for i, item in enumerate(command[:-1]) if item == "-p"]
        observed = []
        skipped = []
        with subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                              errors="backslashreplace") as child:
            for line in child.stdout:
                print(line, end="", flush=True)
                match = re.match(r"ok \d+ (.+?)(?: #.*)?$", line.rstrip())
                if match:
                    observed.append(match.group(1))
                    if re.search(r" #\s*SKIP\b", line, re.IGNORECASE):
                        skipped.append(match.group(1))
            status = child.wait()
        if status != 0:
            return status
        missing = [path for path in requested
                   if not any(test == path or test.startswith(path + "/") for test in observed)]
        if not observed or missing:
            print(f"FAIL: requested tests did not run: {missing or command}", flush=True)
            return 1
        if skipped:
            print(f"SKIP: native cases were unavailable: {skipped}", flush=True)
            return 77
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
