#!/usr/bin/env python3
"""Offline regression checks for the single clean DEB compilation and its gates."""

import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
from tempfile import TemporaryDirectory


PROJECT = Path(__file__).resolve().parent.parent
MOCK = r'''
import json, os, pathlib, sys
name = sys.argv[1]
args = sys.argv[2:]
root = pathlib.Path(os.environ["DINOX_TEST_ROOT"])
with open(os.environ["DINOX_TEST_EVENTS"], "a") as stream:
    stream.write(json.dumps([name, args, os.getcwd()]) + "\n")
mode = os.environ.get("DINOX_TEST_MODE", "")
if name == "verify-ci-deps.sh":
    sys.exit(1 if mode == "dependencies" else 0)
if name == "prepare-ibus-compat.sh":
    assert args == ["--prefix", str(root / ".vendor-deps/ibus-compat-deb")]
    sys.exit(1 if mode == "ibus" else 0)
if name == "package-runtime-matrix.sh":
    assert args == ["system", str(root / "build-deb-package")]
    sys.exit(1 if mode == "matrix" else 0)
if name == "meson":
    if args[0] == "setup":
        target = pathlib.Path(args[1])
        assert args[2] == str(root), "package configuration used the caller as its source"
        assert not target.exists(), "package configuration reused a previous build"
        assert "--buildtype=debugoptimized" in args
        assert "-Ddnssec=enabled" in args
        if mode == "setup": sys.exit(1)
        for relative in ["build.ninja", "qlite/libqlite.so.0.1", "plugins/ice/ice.so",
                         "plugins/omemo/omemo.so", "plugins/mqtt/mqtt.so",
                         "xmpp-vala/libxmpp-vala.so.0.1"]:
            file = target / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("mock output")
    elif args[0] == "compile":
        assert args[1:3] == ["-C", str(root / "build-deb-package")]
        assert args[3:] == ["-j", "2"]
    elif args[0] == "install":
        assert "--no-rebuild" in args
        # Stop at the installation boundary: never construct/install a fake DEB.
        sys.exit(73)
    else:
        raise AssertionError(args)
elif name == "ninja":
    if args == ["clean"]: sys.exit(0)
    assert args == ["-j", "2"], args
    if mode == "compile": sys.exit(1)
    if mode == "warning": print("test.vala:12.3: warning: injected compiler warning")
elif name == "readelf":
    file = pathlib.Path(args[-1]).name
    if mode == "dns" and file == "libxmpp-vala.so.0.1": sys.exit(0)
    needed = {"libqlite.so.0.1": "libsqlcipher.so.0", "ice.so": "libnice.so.10",
              "omemo.so": "libomemo-c.so.0", "mqtt.so": "libmosquitto.so.1",
              "libxmpp-vala.so.0.1": "libunbound.so.8"}[file]
    print(" (NEEDED) Shared library: [" + needed + "]")
'''


class Fixture:
    def __init__(self, root):
        self.root = root
        self.events = root / "events.jsonl"
        scripts = root / "scripts"
        scripts.mkdir()
        for name in ("build.sh", "build-deb.sh", "compiler-warning-report.py"):
            shutil.copyfile(PROJECT / "scripts" / name, scripts / name)
        (root / "VERSION").write_text("1.2.3\n")
        self.prefix = root / "private"
        (self.prefix / "lib/pkgconfig").mkdir(parents=True)
        (self.prefix / "bin").mkdir()
        dispatcher = root / "mock.py"
        dispatcher.write_text(MOCK)
        for path in [scripts / "verify-ci-deps.sh", scripts / "prepare-ibus-compat.sh",
                     scripts / "package-runtime-matrix.sh",
                     *(self.prefix / "bin" / name for name in ("meson", "ninja", "readelf"))]:
            command = shlex.join([sys.executable, str(dispatcher), path.name])
            path.write_text('#!/usr/bin/env bash\nexec ' + command + ' "$@"\n')
            path.chmod(0o755)
        (root / "build").mkdir()
        (root / "build/workstation-marker").write_text("untouched")
        (root / "build-deb-package").mkdir()
        (root / "build-deb-package/stale-marker").write_text("must be removed")

    def run(self, script, arguments=(), mode="", cwd=None, overrides=None):
        self.events.unlink(missing_ok=True)
        env = os.environ.copy()
        for name in ("DINOX_BUILD_JOBS", "DINOX_LIBWEBRTC_ARTIFACT_ROOT"):
            env.pop(name, None)
        env.update({"DINOX_CUSTOM_DEPENDENCY_PREFIX": str(self.prefix),
                    "DINOX_LIBWEBRTC_RUNTIME_ROOT": str(self.root / "runtime"),
                    "DINOX_CI_JOBS": "2", "DINOX_TEST_EVENTS": str(self.events),
                    "DINOX_TEST_ROOT": str(self.root),
                    "DINOX_TEST_MODE": mode,
                    "PATH": str(self.prefix / "bin") + os.pathsep + env["PATH"]})
        env.update(overrides or {})
        result = subprocess.run(["bash", str(self.root / "scripts" / script), *arguments],
                                cwd=cwd or self.root, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
        events = [json.loads(line) for line in self.events.read_text().splitlines()] if self.events.exists() else []
        return result, events


def check_package_flow(root):
    fixture = Fixture(root)
    result, events = fixture.run("build-deb.sh", ["--strict"])
    assert result.returncode == 73, result.stdout
    assert [event[0] for event in events] == [
        "verify-ci-deps.sh", "prepare-ibus-compat.sh", "meson", "ninja",
        "readelf", "readelf", "readelf", "readelf", "readelf",
        "package-runtime-matrix.sh", "meson"], events
    assert next(event for event in events if event[0] == "ninja")[2] \
        == str(root / "build-deb-package"), events
    assert events[-1][1] == ["install", "--no-rebuild", "-C", str(root / "build-deb-package")]
    assert (root / "build/workstation-marker").read_text() == "untouched"
    assert not (root / "build-deb-package/stale-marker").exists()

    for mode in ("dependencies", "ibus", "setup", "compile", "warning", "dns", "matrix"):
        result, events = fixture.run("build-deb.sh", ["--strict"], mode=mode)
        assert result.returncode == 1, (mode, result.stdout)
        assert not any(event[0] == "meson" and event[1][0] == "install" for event in events), events
        if mode in ("dependencies", "ibus", "setup"):
            assert not any(event[0] == "ninja" for event in events), events
        if mode == "ibus":
            assert not any(event[0] == "meson" for event in events), events
        if mode in ("compile", "warning"):
            assert not any(event[0] == "package-runtime-matrix.sh" for event in events), events

    # The non-strict package CLI remains supported and still builds only once.
    result, events = fixture.run("build-deb.sh")
    assert result.returncode == 73, result.stdout
    assert [e[1][0] for e in events if e[0] == "meson"] == ["setup", "compile", "install"]
    assert not any(e[0] == "ninja" for e in events)

    # Absolute script invocations must still configure the checkout, not cwd.
    caller = root / "external caller"
    caller.mkdir()
    result, events = fixture.run("build-deb.sh", cwd=caller)
    assert result.returncode == 73, result.stdout
    setup = next(event for event in events if event[0] == "meson" and event[1][0] == "setup")
    assert setup[2] == str(caller), setup


def check_wrapper_cli(root):
    fixture = Fixture(root)
    (root / "build/build.ninja").write_text("configured")
    caller = root / "caller"
    custom = caller / "custom build"
    custom.mkdir(parents=True)
    (custom / "build.ninja").write_text("configured")
    for args, expected in [([], root / "build"),
                           (["--build-dir", "custom build"], custom),
                           (["--build-dir", str(custom), "--strict", "--clean"], custom)]:
        result, events = fixture.run("build.sh", args, cwd=caller)
        assert result.returncode == 0, result.stdout
        assert events and all(e[2] == str(expected) for e in events), events
        assert events[-1][1] == ["-j", "2"], events
    for args in (["--build-dir"], ["--build-dir", ""], ["--build-dir", "--strict"], ["--unknown"]):
        result, events = fixture.run("build.sh", args)
        assert result.returncode == 2 and not events, (args, result.stdout)
    result, events = fixture.run("build.sh", ["--build-dir", "missing"])
    assert result.returncode == 1 and not events, result.stdout
    result, events = fixture.run("build.sh", overrides={"DINOX_BUILD_JOBS": "invalid"})
    assert result.returncode == 2 and not events, result.stdout
    for script in ("build.sh", "build-deb.sh"):
        result, events = fixture.run(script, ["--help"])
        assert result.returncode == 0 and not events, result.stdout


def main():
    with TemporaryDirectory(prefix="dinox-deb-build-flow-") as directory:
        root = Path(directory)
        for name, check in [("package with spaces", check_package_flow), ("wrapper", check_wrapper_cli)]:
            path = root / name
            path.mkdir()
            check(path)
    print("DEB build flow PASS: one fresh optimized compilation, strict/error gates, same-tree matrix, no install rebuild")


if __name__ == "__main__":
    main()
