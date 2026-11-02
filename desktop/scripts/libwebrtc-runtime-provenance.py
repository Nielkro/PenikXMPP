#!/usr/bin/env python3

import argparse
import functools
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from unittest import mock


COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
BUILD_STAMP_NAME = "dinox-libwebrtc-wrapper-provenance.json"
BUILD_STAMP_KIND = "dinox-libwebrtc-wrapper-build"
BUILD_STAMP_SCHEMA = 1


class ProvenanceError(RuntimeError):
    pass


@functools.lru_cache(maxsize=1)
def local_git_environment_variables() -> tuple[str, ...]:
    # Git hooks export repository-local variables. Even `git -C other init`
    # follows an inherited GIT_DIR and can reinitialize the caller's repository.
    # Discover Git's own list without inheriting any Git-specific configuration
    # for this read-only probe; no repository is needed by --local-env-vars.
    environment = {
        name: value for name, value in os.environ.items()
        if not name.startswith("GIT_")
    }
    environment["LC_ALL"] = "C"
    result = subprocess.run(
        ["git", "rev-parse", "--local-env-vars"],
        cwd=tempfile.gettempdir(),
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
    )
    names = tuple(result.stdout.splitlines())
    required = {"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE"}
    if (result.returncode != 0 or not required.issubset(names)
            or any(not re.fullmatch(r"GIT_[A-Z0-9_]+", name) for name in names)):
        raise ProvenanceError("could not determine repository-local Git environment variables")
    return names


def run_git(repository: pathlib.Path, *arguments: str) -> str:
    environment = os.environ.copy()
    for name in local_git_environment_variables():
        environment.pop(name, None)
    environment["LC_ALL"] = "C"
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown Git error"
        raise ProvenanceError(detail)
    return result.stdout.strip()


def clean_source_commit(repository: pathlib.Path) -> str:
    if run_git(repository, "rev-parse", "--is-inside-work-tree") != "true":
        raise ProvenanceError(f"not a Git worktree: {repository}")

    commit = run_git(repository, "rev-parse", "--verify", "HEAD^{commit}")
    if not COMMIT_PATTERN.fullmatch(commit):
        raise ProvenanceError(f"invalid DinoX source commit: {commit!r}")

    status = run_git(
        repository,
        "status",
        "--porcelain=v1",
        "--untracked-files=normal",
    )
    if status:
        raise ProvenanceError(
            "DinoX source tree is dirty; commit or remove all tracked and "
            "untracked changes before building a runtime"
        )
    return commit


def validate_manifest(manifest_path: pathlib.Path, expected_commit: str | None) -> str:
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProvenanceError(f"could not read runtime manifest: {error}") from error

    if not isinstance(manifest, dict):
        raise ProvenanceError("runtime manifest root must be a JSON object")

    commit = manifest.get("dinox_source_commit")
    if not isinstance(commit, str) or not COMMIT_PATTERN.fullmatch(commit):
        raise ProvenanceError(
            "manifest dinox_source_commit must be a lowercase 40-character Git commit"
        )
    if manifest.get("dinox_source_dirty") is not False:
        raise ProvenanceError("manifest dinox_source_dirty must be false")

    if expected_commit is not None:
        if not COMMIT_PATTERN.fullmatch(expected_commit):
            raise ProvenanceError(
                f"invalid expected DinoX source commit: {expected_commit!r}"
            )
        if commit != expected_commit:
            raise ProvenanceError(
                f"manifest dinox_source_commit is {commit!r}, expected {expected_commit!r}"
            )
    return commit


def read_json_object(path: pathlib.Path, label: str) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProvenanceError(f"could not read {label}: {error}") from error
    if not isinstance(data, dict):
        raise ProvenanceError(f"{label} root must be a JSON object")
    return data


def meson_source_root(build_directory: pathlib.Path) -> pathlib.Path:
    information = read_json_object(
        build_directory / "meson-info" / "meson-info.json",
        "Meson build information",
    )
    try:
        source = information["directories"]["source"]
    except (KeyError, TypeError) as error:
        raise ProvenanceError("Meson build information has no source directory") from error
    if not isinstance(source, str) or not source:
        raise ProvenanceError("Meson source directory is invalid")
    return pathlib.Path(source).resolve()


def build_stamp_path(build_directory: pathlib.Path) -> pathlib.Path:
    return build_directory / BUILD_STAMP_NAME


def validate_expected_commit(expected_commit: str) -> None:
    if not COMMIT_PATTERN.fullmatch(expected_commit):
        raise ProvenanceError(
            f"invalid expected DinoX source commit: {expected_commit!r}"
        )


def write_build_stamp(
    build_directory: pathlib.Path,
    repository: pathlib.Path,
    expected_commit: str,
) -> pathlib.Path:
    build_directory = build_directory.resolve()
    repository = repository.resolve()
    validate_expected_commit(expected_commit)
    current_commit = clean_source_commit(repository)
    if current_commit != expected_commit:
        raise ProvenanceError(
            "DinoX source commit changed while configuring the wrapper build"
        )
    configured_source = meson_source_root(build_directory)
    if configured_source != repository:
        raise ProvenanceError(
            f"Meson build belongs to a different DinoX source tree: {configured_source}"
        )

    stamp_path = build_stamp_path(build_directory)
    temporary_path = stamp_path.with_name(f".{stamp_path.name}.{os.getpid()}.tmp")
    data = {
        "dinox_source_commit": current_commit,
        "dinox_source_dirty": False,
        "dinox_source_root": str(repository),
        "kind": BUILD_STAMP_KIND,
        "schema": BUILD_STAMP_SCHEMA,
    }
    try:
        temporary_path.write_text(
            json.dumps(data, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        temporary_path.replace(stamp_path)
    except OSError as error:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass
        raise ProvenanceError(f"could not write wrapper build provenance: {error}") from error
    return stamp_path


def validate_build_stamp(
    build_directory: pathlib.Path,
    repository: pathlib.Path,
    expected_commit: str,
) -> pathlib.Path:
    build_directory = build_directory.resolve()
    repository = repository.resolve()
    validate_expected_commit(expected_commit)
    current_commit = clean_source_commit(repository)
    if current_commit != expected_commit:
        raise ProvenanceError(
            f"current DinoX source commit is {current_commit!r}, expected {expected_commit!r}"
        )
    configured_source = meson_source_root(build_directory)
    if configured_source != repository:
        raise ProvenanceError(
            f"Meson build belongs to a different DinoX source tree: {configured_source}"
        )

    stamp_path = build_stamp_path(build_directory)
    stamp = read_json_object(stamp_path, "wrapper build provenance")
    expected = {
        "dinox_source_commit": expected_commit,
        "dinox_source_dirty": False,
        "dinox_source_root": str(repository),
        "kind": BUILD_STAMP_KIND,
        "schema": BUILD_STAMP_SCHEMA,
    }
    for key, value in expected.items():
        if stamp.get(key) != value:
            raise ProvenanceError(
                f"wrapper build provenance {key} is {stamp.get(key)!r}, expected {value!r}"
            )
    return stamp_path


def expect_failure(function, *arguments) -> None:
    try:
        function(*arguments)
    except ProvenanceError:
        return
    raise ProvenanceError("self-test expected a provenance failure")


def test_inherited_repository_environment(root: pathlib.Path) -> None:
    decoy = root / "decoy"
    decoy.mkdir()
    run_git(decoy, "init", "--quiet")
    run_git(decoy, "config", "user.name", "DinoX Decoy")
    run_git(decoy, "config", "user.email", "test@dinox.im")
    run_git(decoy, "config", "core.hooksPath", os.devnull)
    (decoy / "keep.txt").write_text("decoy must remain unchanged\n", encoding="utf-8")
    run_git(decoy, "add", "keep.txt")
    run_git(decoy, "commit", "--quiet", "-m", "decoy fixture")
    decoy_commit = clean_source_commit(decoy)

    def snapshot() -> dict[str, bytes]:
        return {
            str(path.relative_to(decoy)): path.read_bytes()
            for path in decoy.rglob("*") if path.is_file()
        }

    before = snapshot()
    repository = root / "hook-inherited-repository"
    repository.mkdir()
    inherited = {
        "GIT_DIR": str(decoy / ".git"),
        "GIT_COMMON_DIR": str(decoy / ".git"),
        "GIT_WORK_TREE": str(decoy),
        "GIT_INDEX_FILE": str(decoy / ".git/index"),
        "GIT_OBJECT_DIRECTORY": str(decoy / ".git/objects"),
        "GIT_CONFIG_PARAMETERS": "'core.bare=true'",
    }
    with mock.patch.dict(os.environ, inherited):
        # Exercise discovery itself with hook variables present, not only the
        # cached list obtained while creating the isolated decoy.
        local_git_environment_variables.cache_clear()
        run_git(repository, "init", "--quiet")
        if not (repository / ".git").is_dir():
            raise ProvenanceError("self-test init followed inherited Git metadata")
        run_git(repository, "config", "user.name", "DinoX Test")
        run_git(repository, "config", "user.email", "test@dinox.im")
        run_git(repository, "config", "core.hooksPath", os.devnull)
        (repository / "target.txt").write_text("requested repository\n", encoding="utf-8")
        run_git(repository, "add", "target.txt")
        run_git(repository, "commit", "--quiet", "-m", "isolated target fixture")
        target_commit = clean_source_commit(repository)
        if target_commit == decoy_commit:
            raise ProvenanceError("self-test provenance resolved the decoy commit")
        if run_git(repository, "ls-files") != "target.txt":
            raise ProvenanceError("self-test staging followed the inherited index")
        if run_git(repository, "config", "--get", "core.bare") != "false":
            raise ProvenanceError("self-test inherited repository configuration")
        if clean_source_commit(decoy) != decoy_commit:
            raise ProvenanceError("self-test changed the decoy commit")
    if snapshot() != before:
        raise ProvenanceError("self-test mutated files outside the requested repository")


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="dinox-runtime-provenance-") as temporary:
        root = pathlib.Path(temporary)
        test_inherited_repository_environment(root)
        repository = root / "repository"
        repository.mkdir()
        run_git(repository, "init", "--quiet")
        run_git(repository, "config", "user.name", "DinoX Test")
        run_git(repository, "config", "user.email", "test@dinox.im")
        run_git(repository, "config", "core.hooksPath", os.devnull)
        (repository / "tracked.txt").write_text("clean\n", encoding="utf-8")
        run_git(repository, "add", "tracked.txt")
        run_git(repository, "commit", "--quiet", "-m", "provenance fixture")

        commit = clean_source_commit(repository)
        build_directory = root / "build"
        (build_directory / "meson-info").mkdir(parents=True)
        (build_directory / "meson-info" / "meson-info.json").write_text(
            json.dumps(
                {
                    "directories": {
                        "build": str(build_directory),
                        "source": str(repository),
                    }
                }
            )
            + "\n",
            encoding="utf-8",
        )
        stamp_path = write_build_stamp(build_directory, repository, commit)
        validate_build_stamp(build_directory, repository, commit)

        (repository / "next.txt").write_text("next commit\n", encoding="utf-8")
        run_git(repository, "add", "next.txt")
        run_git(repository, "commit", "--quiet", "-m", "next provenance fixture")
        next_commit = clean_source_commit(repository)
        expect_failure(
            validate_build_stamp,
            build_directory,
            repository,
            next_commit,
        )
        stamp_path = write_build_stamp(build_directory, repository, next_commit)
        validate_build_stamp(build_directory, repository, next_commit)
        commit = next_commit

        stamp = json.loads(stamp_path.read_text(encoding="utf-8"))
        stamp["dinox_source_commit"] = "0" * 40
        stamp_path.write_text(json.dumps(stamp) + "\n", encoding="utf-8")
        expect_failure(validate_build_stamp, build_directory, repository, commit)
        stamp_path.unlink()
        expect_failure(validate_build_stamp, build_directory, repository, commit)
        write_build_stamp(build_directory, repository, commit)

        manifest_path = root / "manifest.json"
        manifest_path.write_text(
            json.dumps(
                {
                    "dinox_source_commit": commit,
                    "dinox_source_dirty": False,
                }
            )
            + "\n",
            encoding="utf-8",
        )
        validate_manifest(manifest_path, commit)

        (repository / "untracked.txt").write_text("dirty\n", encoding="utf-8")
        expect_failure(clean_source_commit, repository)
        (repository / "untracked.txt").unlink()

        (repository / "tracked.txt").write_text("modified\n", encoding="utf-8")
        expect_failure(clean_source_commit, repository)
        run_git(repository, "restore", "tracked.txt")

        (repository / "staged.txt").write_text("staged\n", encoding="utf-8")
        run_git(repository, "add", "staged.txt")
        expect_failure(clean_source_commit, repository)
        run_git(repository, "reset", "--quiet", "HEAD", "staged.txt")
        (repository / "staged.txt").unlink()

        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["dinox_source_dirty"] = True
        manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        expect_failure(validate_manifest, manifest_path, commit)

        manifest["dinox_source_dirty"] = False
        manifest["dinox_source_commit"] = "not-a-commit"
        manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        expect_failure(validate_manifest, manifest_path, commit)

        manifest["dinox_source_commit"] = commit
        manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        expect_failure(validate_manifest, manifest_path, "0" * 40)

    print("Self-test OK")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate DinoX source provenance for libwebrtc runtimes."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    source_parser = subparsers.add_parser(
        "source-commit", help="print HEAD only when the DinoX worktree is clean"
    )
    source_parser.add_argument("repository", type=pathlib.Path)

    manifest_parser = subparsers.add_parser(
        "manifest", help="validate DinoX provenance in a runtime manifest"
    )
    manifest_parser.add_argument("manifest", type=pathlib.Path)
    manifest_parser.add_argument("expected_commit", nargs="?")

    write_stamp_parser = subparsers.add_parser(
        "write-build-stamp",
        help="record the clean DinoX commit after Meson configuration",
    )
    write_stamp_parser.add_argument("build_directory", type=pathlib.Path)
    write_stamp_parser.add_argument("repository", type=pathlib.Path)
    write_stamp_parser.add_argument("expected_commit")

    check_stamp_parser = subparsers.add_parser(
        "check-build-stamp",
        help="validate the configured wrapper build against a DinoX commit",
    )
    check_stamp_parser.add_argument("build_directory", type=pathlib.Path)
    check_stamp_parser.add_argument("repository", type=pathlib.Path)
    check_stamp_parser.add_argument("expected_commit")

    subparsers.add_parser("self-test", help="run isolated provenance fixtures")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.command == "source-commit":
            print(clean_source_commit(arguments.repository.resolve()))
        elif arguments.command == "manifest":
            validate_manifest(arguments.manifest, arguments.expected_commit)
        elif arguments.command == "write-build-stamp":
            print(
                write_build_stamp(
                    arguments.build_directory,
                    arguments.repository,
                    arguments.expected_commit,
                )
            )
        elif arguments.command == "check-build-stamp":
            validate_build_stamp(
                arguments.build_directory,
                arguments.repository,
                arguments.expected_commit,
            )
        else:
            self_test()
    except ProvenanceError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
