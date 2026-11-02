#!/usr/bin/env python3
"""Check provider snapshot replacement with isolated downloads and parser results."""

from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


UPDATER_PATH = Path(__file__).resolve().with_name("update-provider-snapshot.py")
SPEC = importlib.util.spec_from_file_location("provider_snapshot_updater", UPDATER_PATH)
assert SPEC is not None and SPEC.loader is not None
UPDATER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPDATER)


class ProviderSnapshotUpdateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.directory = Path(self.temporary_directory.name)
        self.snapshot = self.directory / "snapshot.json"
        self.original = b'[{"jid":"last-good.example"}]\n'
        self.candidate = b'[{"jid":"new.example"}]\n'
        self.snapshot.write_bytes(self.original)
        self.args = argparse.Namespace(
            source_url="https://mirror.example/providers.json",
            snapshot=self.snapshot,
            build_dir=self.directory / "build",
            self_test=False,
            update=True,
        )

    def download(self, url: str) -> bytes:
        if url == self.args.source_url:
            return self.candidate
        self.assertEqual(url, self.args.source_url + ".sha256")
        return (UPDATER.sha256_hex(self.candidate) + "  providers.json\n").encode("ascii")

    def run_update(self, validate) -> int:
        with patch.object(UPDATER, "parse_args", return_value=self.args), \
                patch.object(UPDATER, "fetch_limited", side_effect=self.download), \
                patch.object(UPDATER, "run_parser_validation", side_effect=validate), \
                contextlib.redirect_stdout(io.StringIO()):
            return UPDATER.main()

    def assert_no_candidates(self) -> None:
        self.assertEqual(list(self.directory.iterdir()), [self.snapshot])

    def test_schema_rejection_with_valid_checksum_preserves_snapshot(self) -> None:
        self.candidate = b"{}\n"

        def reject(build_dir: Path, candidate: Path) -> None:
            self.assertNotEqual(candidate, self.snapshot)
            self.assertEqual(candidate.read_bytes(), self.candidate)
            self.assertEqual(self.snapshot.read_bytes(), self.original)
            raise subprocess.CalledProcessError(1, ["meson", "test"])

        with self.assertRaises(subprocess.CalledProcessError):
            self.run_update(reject)
        self.assertEqual(self.snapshot.read_bytes(), self.original)
        self.assert_no_candidates()

    def test_valid_candidate_is_checked_before_replacement(self) -> None:
        checked_paths = []

        def accept(build_dir: Path, candidate: Path) -> None:
            self.assertEqual(build_dir, self.args.build_dir)
            self.assertNotEqual(candidate, self.snapshot)
            self.assertEqual(candidate.parent, self.snapshot.parent)
            self.assertEqual(candidate.read_bytes(), self.candidate)
            self.assertEqual(self.snapshot.read_bytes(), self.original)
            checked_paths.append(candidate)

        self.assertEqual(self.run_update(accept), 0)
        self.assertEqual(len(checked_paths), 1)
        self.assertFalse(checked_paths[0].exists())
        self.assertEqual(self.snapshot.read_bytes(), self.candidate)
        self.assert_no_candidates()

    def test_failed_initial_candidate_does_not_create_snapshot(self) -> None:
        self.snapshot.unlink()

        def reject(*_) -> None:
            raise subprocess.CalledProcessError(1, ["meson", "test"])

        with self.assertRaises(subprocess.CalledProcessError):
            self.run_update(reject)
        self.assertFalse(self.snapshot.exists())
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_checksum_failure_leaves_snapshot_unchanged(self) -> None:
        with patch.object(UPDATER, "parse_args", return_value=self.args), \
                patch.object(UPDATER, "fetch_limited", side_effect=[self.candidate, b"0" * 64]), \
                patch.object(UPDATER, "run_parser_validation") as validate, \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                UPDATER.main()
        validate.assert_not_called()
        self.assertEqual(self.snapshot.read_bytes(), self.original)
        self.assert_no_candidates()

    def test_replace_failure_preserves_snapshot_and_removes_candidate(self) -> None:
        with patch.object(UPDATER.os, "replace", side_effect=PermissionError("snapshot is locked")):
            with self.assertRaises(PermissionError):
                self.run_update(lambda *_: None)
        self.assertEqual(self.snapshot.read_bytes(), self.original)
        self.assert_no_candidates()

    def test_validation_exit_cleans_up_candidate(self) -> None:
        def reject(candidate: Path) -> None:
            raise SystemExit(1)

        with self.assertRaises(SystemExit):
            UPDATER.write_atomic(self.snapshot, self.candidate, reject)
        self.assertEqual(self.snapshot.read_bytes(), self.original)
        self.assert_no_candidates()

    def test_check_validates_existing_snapshot_without_download(self) -> None:
        self.args.update = False
        with patch.object(UPDATER, "parse_args", return_value=self.args), \
                patch.object(UPDATER, "fetch_limited") as fetch, \
                patch.object(UPDATER, "run_parser_validation") as validate, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(UPDATER.main(), 0)
        fetch.assert_not_called()
        validate.assert_called_once_with(self.args.build_dir, self.snapshot)
        self.assertEqual(self.snapshot.read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()
