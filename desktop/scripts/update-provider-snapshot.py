#!/usr/bin/env python3
"""Refresh and validate the bundled XMPP provider snapshot."""

from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable


REPO = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE_URL = "https://dinox.im/data/providers/v2/providers-B.json"
DEFAULT_SNAPSHOT = REPO / "main" / "data" / "providers-v2-B.json"
DEFAULT_BUILD_DIR = REPO / "build"
MAX_RESPONSE_BYTES = 256 * 1024


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch_limited(url: str) -> bytes:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or not parsed.netloc:
        fail(f"source URL must be HTTPS: {url}")

    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": "DinoX bundled provider snapshot updater",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        final_url = response.geturl()
        final_parsed = urllib.parse.urlparse(final_url)
        if final_parsed.scheme != "https":
            fail(f"source URL redirected away from HTTPS: {final_url}")
        status = getattr(response, "status", 200)
        if status != 200:
            fail(f"source URL returned HTTP {status}")
        data = response.read(MAX_RESPONSE_BYTES + 1)

    if len(data) > MAX_RESPONSE_BYTES:
        fail(f"source response exceeds {MAX_RESPONSE_BYTES} bytes")
    if not data:
        fail("source response is empty")
    return data


def verify_sidecar(source_url: str, data: bytes) -> None:
    sidecar = fetch_limited(source_url + ".sha256").decode("utf-8").strip()
    expected_hash = sidecar.split()[0] if sidecar else ""
    actual_hash = sha256_hex(data)
    if expected_hash != actual_hash:
        fail(f"downloaded provider snapshot hash mismatch: {actual_hash} != {expected_hash}")


def write_atomic(path: Path, data: bytes, validate: Callable[[Path], None] | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        # Close the candidate before validation and replacement, also on Windows.
        # A failed validation must leave the last-known-good snapshot untouched.
        if validate is not None:
            validate(Path(tmp_name))
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise


def run_parser_validation(build_dir: Path, snapshot: Path) -> None:
    if not build_dir.exists():
        fail(f"build directory does not exist: {build_dir}")

    subprocess.run(
        ["meson", "compile", "-C", str(build_dir), "main-test"],
        cwd=REPO,
        check=True,
    )
    env = os.environ.copy()
    env["DINOX_PROVIDER_DIRECTORY_TEST_JSON"] = str(snapshot)
    subprocess.run(
        ["meson", "test", "-C", str(build_dir), "Tests for main", "--print-errorlogs"],
        cwd=REPO,
        env=env,
        check=True,
    )


def self_test() -> None:
    sample = b"[{\"jid\":\"example.org\"}]\n"
    if sha256_hex(sample) != hashlib.sha256(sample).hexdigest():
        fail("sha256 self-test failed")

    with tempfile.TemporaryDirectory() as tmp_dir:
        target = Path(tmp_dir) / "snapshot.json"
        write_atomic(target, sample)
        if target.read_bytes() != sample:
            fail("atomic write self-test failed")

    print("Self-test passed.")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-url", default=DEFAULT_SOURCE_URL)
    parser.add_argument("--snapshot", type=Path, default=DEFAULT_SNAPSHOT)
    parser.add_argument("--build-dir", type=Path, default=DEFAULT_BUILD_DIR)
    parser.add_argument("--check", action="store_true", help="validate the current bundled snapshot")
    parser.add_argument("--update", action="store_true", help="download, validate, and replace the bundled snapshot")
    parser.add_argument("--self-test", action="store_true", help="run updater self-tests")
    args = parser.parse_args()

    selected = sum(1 for value in (args.check, args.update, args.self_test) if value)
    if selected != 1:
        parser.error("select exactly one of --check, --update, or --self-test")
    return args


def main() -> int:
    args = parse_args()
    if args.self_test:
        self_test()
        return 0

    if args.update:
        data = fetch_limited(args.source_url)
        verify_sidecar(args.source_url, data)
        write_atomic(args.snapshot, data, lambda candidate: run_parser_validation(args.build_dir, candidate))
    else:
        run_parser_validation(args.build_dir, args.snapshot)
    print(f"Snapshot valid: {args.snapshot}")
    print(f"SHA-256: {sha256_hex(args.snapshot.read_bytes())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
