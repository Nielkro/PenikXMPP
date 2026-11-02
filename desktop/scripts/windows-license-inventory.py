#!/usr/bin/env python3
"""Stage and verify the portable Windows PE license inventory."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path


INVENTORY_NAME = "WINDOWS-PE-INVENTORY.tsv"
ASSET_INVENTORY_NAME = "WINDOWS-ASSET-INVENTORY.tsv"
STATIC_INVENTORY_NAME = "WINDOWS-STATIC-COMPONENTS.tsv"
LICENSE_FILE_INVENTORY_NAME = "WINDOWS-LICENSE-FILES.tsv"
NOTICE_NAME = "THIRD_PARTY_NOTICES.md"
UTF8_MANIFEST_MARKER = (
    b'<activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">'
    b"UTF-8</activeCodePage>"
)
TOR_PACKAGE_NAME = "mingw-w64-x86_64-tor"
TOR_PACKAGE_VERSION = "0.4.9.12-1"
OPENSSL_PACKAGE_NAME = "mingw-w64-x86_64-openssl"
MAX_LICENSE_TREE_BYTES = 16 * 1024 * 1024
MAX_LICENSE_FILE_BYTES = 2 * 1024 * 1024
INVENTORY_HEADER = (
    "path",
    "sha256",
    "origin",
    "component",
    "version",
    "declared_license",
    "source_reference",
    "notice_path",
)
STATIC_INVENTORY_HEADER = (
    "path",
    "sha256",
    "component",
    "version",
    "declared_license",
    "source_reference",
    "notice_path",
)
LICENSE_FILE_INVENTORY_HEADER = (
    "path",
    "sha256",
    "size",
)
GO_MODULE_HEADER = (
    "requested_module",
    "requested_version",
    "resolved_module",
    "resolved_version",
    "module_sum",
    "replacement_sum",
    "license_paths",
)
FORBIDDEN_ARCHIVE_SUFFIXES = (
    ".zip",
    ".7z",
    ".rar",
    ".tar",
    ".tar.gz",
    ".tgz",
    ".tar.xz",
    ".txz",
    ".tar.bz2",
    ".tbz2",
    ".pkg.tar.zst",
    ".deb",
    ".dsc",
    ".zst",
)
CUSTOM_COMPONENTS = {
    "glib-networking-dinox": {
        "version": "2.80.1",
        "directory": "glib-networking-2.80.1-dinox",
        "checksum_algorithm": "sha256",
        "checksum": "b80e2874157cd55071f1b6710fa0b911d5ac5de106a9ee2a4c9c7bee61782f8e",
    },
    "libomemo-c": {
        "version": "0.5.1",
        "directory": "libomemo-c-0.5.1",
        "checksum_algorithm": "sha512",
        "checksum": (
            "ff59565406c51663f2944e9a7c12c5b0e3fa01073039f5161472dd81f59194b1"
            "cf2685bc1e0cc930a141bc409b965c5d93313cfc3e0e237250102af3b5e88826"
        ),
    },
    "lyrebird": {
        "version": "0.8.1",
        "directory": "lyrebird-0.8.1",
        "checksum_algorithm": "sha256",
        "checksum": "05d87533c66562baae8a0adac6ae7f7401aa08516ea0dfd192a367d2f8645092",
    },
}
GENERATED_RUNTIME_ASSET_PATHS = {
    "etc/fonts/fonts.conf",
    "etc/fonts/local.conf",
    "share/glib-2.0/schemas/gschemas.compiled",
}


class InventoryError(RuntimeError):
    pass


@dataclass(frozen=True)
class PackageMetadata:
    name: str
    base: str
    version: str
    licenses: tuple[str, ...]
    url: str
    files: tuple[str, ...]


@dataclass(frozen=True)
class Component:
    origin: str
    name: str
    version: str
    declared_license: str
    source_reference: str
    notice_path: str


def fail(message: str) -> None:
    raise InventoryError(message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def has_pe_signature(path: Path) -> bool:
    with path.open("rb") as handle:
        header = handle.read(64)
        if len(header) != 64 or header[:2] != b"MZ":
            return False
        pe_offset = int.from_bytes(header[0x3C:0x40], byteorder="little")
        if pe_offset < 64 or pe_offset > path.stat().st_size - 4:
            return False
        handle.seek(pe_offset)
        return handle.read(4) == b"PE\0\0"


def pe_files(root: Path) -> list[Path]:
    result: list[Path] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        is_pe = has_pe_signature(path)
        if path.suffix.lower() in {".dll", ".exe"} and not is_pe:
            fail(f"packaged .exe/.dll is not a valid PE file: {path}")
        if is_pe:
            result.append(path)
    result.sort(key=lambda path: path.relative_to(root).as_posix().lower())
    return result


def parse_pacman_sections(path: Path) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = defaultdict(list)
    current: str | None = None
    for raw_line in path.read_text(encoding="utf-8", errors="strict").splitlines():
        if raw_line.startswith("%") and raw_line.endswith("%") and len(raw_line) > 2:
            current = raw_line[1:-1]
        elif raw_line and current is not None:
            sections[current].append(raw_line)
    return dict(sections)


def load_package_database(msys_root: Path) -> tuple[dict[str, PackageMetadata], dict[str, str]]:
    database_root = msys_root / "var/lib/pacman/local"
    if not database_root.is_dir():
        fail(f"MSYS2 package database not found: {database_root}")

    packages: dict[str, PackageMetadata] = {}
    owners: dict[str, str] = {}
    for package_dir in sorted(database_root.iterdir()):
        desc_path = package_dir / "desc"
        files_path = package_dir / "files"
        if not desc_path.is_file() or not files_path.is_file():
            continue
        desc = parse_pacman_sections(desc_path)
        file_sections = parse_pacman_sections(files_path)
        names = desc.get("NAME", [])
        versions = desc.get("VERSION", [])
        if len(names) != 1 or len(versions) != 1:
            fail(f"invalid MSYS2 package metadata: {package_dir}")
        name = names[0]
        metadata = PackageMetadata(
            name=name,
            base=(desc.get("BASE", [name])[0]),
            version=versions[0],
            licenses=tuple(desc.get("LICENSE", [])),
            url=(desc.get("URL", [""])[0]),
            files=tuple(file_sections.get("FILES", [])),
        )
        if name in packages:
            fail(f"duplicate installed MSYS2 package metadata: {name}")
        packages[name] = metadata
        for relative in metadata.files:
            if relative.endswith("/"):
                continue
            previous = owners.setdefault(relative, name)
            if previous != name:
                fail(
                    "MSYS2 package database assigns one file to multiple packages: "
                    f"{relative} ({previous}, {name})"
                )
    if not packages:
        fail(f"no installed MSYS2 packages found in {database_root}")
    return packages, owners


def relevant_hash_index(
    root: Path,
    wanted_names: set[str],
    *,
    excluded_roots: tuple[Path, ...] = (),
) -> dict[tuple[str, str], list[Path]]:
    index: dict[tuple[str, str], list[Path]] = defaultdict(list)
    if not root.is_dir():
        return index
    excluded = tuple(path.resolve() for path in excluded_roots)
    for directory, _subdirs, filenames in os.walk(root):
        current = Path(directory).resolve()
        _subdirs[:] = [
            name
            for name in _subdirs
            if not any(
                (current / name).resolve() == blocked
                or blocked in (current / name).resolve().parents
                for blocked in excluded
            )
        ]
        if any(current == blocked or blocked in current.parents for blocked in excluded):
            continue
        for filename in filenames:
            lowered = filename.lower()
            if lowered not in wanted_names:
                continue
            path = Path(directory) / filename
            index[(lowered, sha256_file(path))].append(path)
    return index


def validate_manifest_transformed_msys2_executable(
    project_root: Path,
    dist_root: Path,
    mingw_root: Path,
    source: Path,
    source_relative: str,
    packaged_relative: str,
    expected_package_name: str,
    expected_package_version: str | None,
    packages: dict[str, PackageMetadata],
    owners: dict[str, str],
    *,
    allow_non_windows_fixture: bool = False,
) -> str:
    """Prove a packaged PE is exactly its MSYS2 source plus our manifest."""
    expected_source = (mingw_root / source_relative).resolve()
    if source != expected_source:
        fail(f"MSYS2 source path is not canonical: {source}")
    if not source.is_file() or source.is_symlink():
        fail(f"MSYS2 source is missing or not a regular file: {source}")

    owner = owners.get(f"mingw64/{source_relative}")
    if owner != expected_package_name:
        fail(
            f"MINGW64 {source_relative} has an unexpected package owner: "
            f"{owner!r}, expected {expected_package_name!r}"
        )
    package = packages.get(owner)
    if package is None or (
        expected_package_version is not None
        and package.version != expected_package_version
    ):
        fail(
            f"{expected_package_name} has version "
            f"{package.version if package is not None else 'missing'}, "
            f"expected {expected_package_version or 'an installed package version'}"
        )

    packaged = dist_root / packaged_relative
    if not packaged.is_file() or packaged.is_symlink():
        fail(f"packaged executable is missing or not a regular file: {packaged}")
    if UTF8_MANIFEST_MARKER not in packaged.read_bytes():
        fail(f"packaged {packaged_relative} has no embedded UTF-8 process manifest")

    helper = project_root / "scripts/embed-windows-utf8-manifest.py"
    manifest = project_root / "main/data/dinox.exe.manifest"
    if not helper.is_file() or not manifest.is_file():
        fail("Windows manifest transformation inputs are missing")
    if allow_non_windows_fixture:
        return owner
    if os.name != "nt":
        fail("Windows manifest transformation verification requires Windows")

    with tempfile.TemporaryDirectory(prefix="dinox-pe-transform-") as temp_text:
        candidate = Path(temp_text) / Path(packaged_relative).name
        shutil.copy2(source, candidate)
        run_command(
            [
                sys.executable,
                str(helper),
                "embed",
                str(candidate),
                str(manifest),
            ],
            capture=True,
        )
        if sha256_file(candidate) != sha256_file(packaged):
            fail(
                f"packaged {packaged_relative} is not its MSYS2 source with "
                "exactly the DinoX UTF-8 manifest transformation"
            )
    return owner


def parse_key_value_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="strict").splitlines():
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not key:
            fail(f"invalid metadata line in {path}: {line!r}")
        if key in values:
            fail(f"duplicate metadata key in {path}: {key}")
        values[key] = value
    return values


def safe_relative_path(value: str) -> Path:
    normalized = value.replace("\\", "/")
    path = Path(normalized)
    if (
        not normalized
        or normalized.startswith("/")
        or re.match(r"^[A-Za-z]:", normalized)
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        fail(f"unsafe relative inventory path: {value!r}")
    return path


def copy_nonempty_tree(source: Path, destination: Path) -> None:
    if not source.is_dir():
        fail(f"license source directory missing: {source}")
    copied = 0
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            fail(f"symlink is not allowed in license material: {path}")
        if not path.is_file():
            continue
        if path.stat().st_size <= 0:
            continue
        relative = path.relative_to(source)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        copied += 1
    if copied == 0:
        fail(f"no non-empty license material found: {source}")


def project_version(project_root: Path) -> str:
    meson = (project_root / "meson.build").read_text(encoding="utf-8")
    match = re.search(r"\bversion:\s*'([^']+)'", meson)
    if not match:
        fail("DinoX version is missing from meson.build")
    return match.group(1)


def project_commit(dist_root: Path) -> str:
    info_path = dist_root / "build-info.txt"
    values = parse_key_value_file(info_path)
    commit = values.get("source_commit", "")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        fail(f"invalid source_commit in {info_path}")
    return commit


def load_custom_component(
    vendor_root: Path,
    license_root: Path,
    component_name: str,
) -> Component:
    expected = CUSTOM_COMPONENTS[component_name]
    source_root = (
        vendor_root / "windows-license-material" / str(expected["directory"])
    )
    metadata_path = source_root / "METADATA"
    files_root = source_root / "files"
    if not metadata_path.is_file():
        fail(f"custom dependency license metadata missing: {metadata_path}")
    metadata = parse_key_value_file(metadata_path)
    required = {
        "component": component_name,
        "version": str(expected["version"]),
        "checksum_algorithm": str(expected["checksum_algorithm"]),
        "checksum": str(expected["checksum"]),
    }
    for key, value in required.items():
        if metadata.get(key) != value:
            fail(
                f"{component_name} license metadata {key}={metadata.get(key)!r}, "
                f"expected {value!r}"
            )
    declared_license = metadata.get("license_expression", "")
    source_url = metadata.get("source_url", "")
    if not declared_license or not source_url.startswith("https://"):
        fail(f"incomplete custom dependency license metadata: {metadata_path}")
    destination_relative = Path("custom") / component_name
    destination = license_root / destination_relative
    copy_nonempty_tree(files_root, destination / "files")
    shutil.copy2(metadata_path, destination / "METADATA")
    return Component(
        origin="custom-source",
        name=component_name,
        version=str(expected["version"]),
        declared_license=declared_license,
        source_reference=source_url,
        notice_path=(
            Path("share/licenses/dinox") / destination_relative
        ).as_posix(),
    )


def load_lyrebird_go_modules(
    vendor_root: Path,
    lyrebird_component: Component,
) -> list[Component]:
    source_root = (
        vendor_root
        / "windows-license-material"
        / str(CUSTOM_COMPONENTS["lyrebird"]["directory"])
        / "files"
    )
    manifest_path = source_root / "toolchain/go/GO-MODULES.tsv"
    if not manifest_path.is_file():
        fail(f"Lyrebird Go module manifest missing: {manifest_path}")
    with manifest_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.reader(handle, dialect="excel-tab")
        try:
            header = tuple(next(reader))
        except StopIteration:
            fail(f"empty Lyrebird Go module manifest: {manifest_path}")
        if header != GO_MODULE_HEADER:
            fail(f"unexpected Lyrebird Go module manifest header: {header!r}")
        rows = list(reader)
    if not rows:
        fail("Lyrebird Go module manifest contains no dependencies")

    components: list[Component] = []
    seen: set[str] = set()
    for line_number, row in enumerate(rows, start=2):
        if len(row) != len(GO_MODULE_HEADER):
            fail(f"invalid Lyrebird Go module row {line_number}")
        (
            requested,
            requested_version,
            resolved,
            resolved_version,
            module_sum,
            replacement_sum,
            license_paths_text,
        ) = row
        if (
            requested in seen
            or not re.fullmatch(r"[A-Za-z0-9._~+/!-]+", requested)
            or not re.fullmatch(r"[A-Za-z0-9._~+/!-]+", resolved)
            or not requested_version
            or not resolved_version
        ):
            fail(f"invalid or duplicate Lyrebird Go module row {line_number}")
        seen.add(requested)
        if module_sum and not module_sum.startswith("h1:"):
            fail(f"invalid Go module sum at row {line_number}")
        if replacement_sum and not replacement_sum.startswith("h1:"):
            fail(f"invalid Go replacement sum at row {line_number}")
        license_paths = license_paths_text.split(";")
        if not license_paths or any(not value for value in license_paths):
            fail(f"Go module has no license paths at row {line_number}")
        module_notice_relative: Path | None = None
        for value in license_paths:
            relative = safe_relative_path(value)
            path = source_root / relative
            if (
                not path.is_file()
                or path.stat().st_size <= 0
                or not looks_like_license_file(path)
            ):
                fail(f"Go module license path is missing or invalid: {value}")
            candidate = relative.parent
            if module_notice_relative is None:
                module_notice_relative = candidate
            elif module_notice_relative != candidate:
                fail(f"Go module license paths span multiple directories: {requested}")
        assert module_notice_relative is not None
        components.append(
            Component(
                origin="go-module",
                name=f"go-module:{requested}",
                version=requested_version,
                declared_license="See staged module license files",
                source_reference=f"https://pkg.go.dev/{resolved}@{resolved_version}",
                notice_path=(
                    Path(lyrebird_component.notice_path)
                    / "files"
                    / module_notice_relative
                ).as_posix(),
            )
        )
    return components


def stage_project_licenses(project_root: Path, license_root: Path) -> None:
    destination = license_root / "dinox"
    destination.mkdir(parents=True, exist_ok=True)
    for filename in ("LICENSE", "NOTICE", "AUTHORS"):
        source = project_root / filename
        if not source.is_file() or source.stat().st_size <= 0:
            fail(f"required DinoX license file missing or empty: {source}")
        shutil.copy2(source, destination / filename)


def run_command(command: list[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        check=False,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        fail(
            f"command failed ({result.returncode}): {' '.join(command)}"
            + (f"\n{detail}" if detail else "")
        )
    return result


def download_file(url: str, destination: Path) -> None:
    partial = destination.with_name(destination.name + ".part")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_file() and destination.stat().st_size > 0:
        return
    partial.unlink(missing_ok=True)
    print(f"Downloading signed MSYS2 source material: {destination.name}")
    run_command(
        [
            "curl",
            "--fail",
            "--location",
            "--retry",
            "3",
            "--proto",
            "=https",
            "--tlsv1.2",
            url,
            "--output",
            str(partial),
        ]
    )
    if not partial.is_file() or partial.stat().st_size <= 0:
        fail(f"downloaded source material is empty: {url}")
    partial.replace(destination)


def verify_detached_signature(
    archive: Path,
    signature: Path,
    keyring: Path,
) -> bool:
    result = subprocess.run(
        [
            "gpgv",
            "--keyring",
            str(keyring),
            str(signature),
            str(archive),
        ],
        check=False,
        # Native gpgv can mix Windows-localized date bytes with UTF-8 text.
        # Drain both pipes as bytes; signature validity is its exit status.
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.returncode == 0


def safe_archive_members(archive: Path) -> list[str]:
    result = run_command(["tar", "-tf", str(archive)], capture=True)
    members = [line for line in result.stdout.splitlines() if line]
    if not members:
        fail(f"source archive has no members: {archive}")
    for member in members:
        normalized = member.replace("\\", "/")
        pure = Path(normalized)
        if (
            normalized.startswith("/")
            or re.match(r"^[A-Za-z]:", normalized)
            or ".." in pure.parts
        ):
            fail(f"unsafe path in source archive {archive}: {member!r}")
    return members


def extract_archive(archive: Path, destination: Path) -> None:
    safe_archive_members(archive)
    destination.mkdir(parents=True, exist_ok=True)
    run_command(["tar", "-xf", str(archive), "-C", str(destination)])


def verify_msys2_source_identity(
    source_root: Path,
    package: PackageMetadata,
) -> None:
    source_info_files = sorted(source_root.rglob(".SRCINFO"))
    if len(source_info_files) != 1:
        fail(
            "signed MSYS2 source package must contain exactly one .SRCINFO: "
            f"{package.base}-{package.version}"
        )
    values: dict[str, list[str]] = defaultdict(list)
    for raw in source_info_files[0].read_text(
        encoding="utf-8", errors="strict"
    ).splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition(" = ")
        if separator:
            values[key].append(value)
    for key in ("pkgbase", "pkgver", "pkgrel"):
        if len(values.get(key, [])) != 1:
            fail(f"MSYS2 .SRCINFO has invalid {key}: {source_info_files[0]}")
    source_version = f"{values['pkgver'][0]}-{values['pkgrel'][0]}"
    epochs = values.get("epoch", [])
    if epochs:
        if len(epochs) != 1 or not epochs[0].isdigit():
            fail(f"MSYS2 .SRCINFO has invalid epoch: {source_info_files[0]}")
        source_version = f"{epochs[0]}:{source_version}"
    if values["pkgbase"][0] != package.base or source_version != package.version:
        fail(
            "signed MSYS2 source identity mismatch: "
            f"got {values['pkgbase'][0]} {source_version}, "
            f"expected {package.base} {package.version}"
        )


def materialize_bare_git_repositories(source_root: Path, temporary: Path) -> list[Path]:
    materialized: list[Path] = []
    candidates = sorted(
        {
            path.parent
            for path in source_root.rglob("HEAD")
            if (path.parent / "objects").is_dir()
            and (path.parent / "config").is_file()
        }
    )
    for repository in candidates:
        probe = run_command(
            [
                "git",
                f"--git-dir={repository}",
                "rev-parse",
                "--is-bare-repository",
            ],
            capture=True,
        )
        if probe.stdout.strip() != "true":
            continue
        number = len(materialized) + 1
        archive = temporary / f"bare-git-{number:04d}.tar"
        destination = temporary / f"bare-git-tree-{number:04d}"
        run_command(
            [
                "git",
                f"--git-dir={repository}",
                "archive",
                "--format=tar",
                f"--output={archive}",
                "HEAD",
            ],
            capture=True,
        )
        extract_archive(archive, destination)
        materialized.append(destination)
    return materialized


def looks_like_source_archive(path: Path) -> bool:
    lowered = path.name.lower()
    return lowered.endswith(
        (
            ".tar",
            ".tar.gz",
            ".tgz",
            ".tar.xz",
            ".txz",
            ".tar.bz2",
            ".tbz2",
            ".tar.zst",
            ".zip",
        )
    )


def looks_like_license_file(path: Path) -> bool:
    name = path.name.upper()
    if name in {"COPYINGV2", "COPYINGV3", "COPYINGV2.1", "COPYINGV3.0"}:
        return True
    return any(
        name == prefix
        or name.startswith(prefix + ".")
        or name.startswith(prefix + "-")
        or name.startswith(prefix + "_")
        for prefix in (
            "COPYING",
            "COPYRIGHT",
            "LICENSE",
            "LICENCE",
            "GPL",
            "LGPL",
            "AGPL",
            "MPL",
            "BSD",
            "MIT",
            "EPL",
            "EDL",
            "NOTICE",
            "PATENTS",
            "UNLICENSE",
        )
    )


def notice_directory_has_license_text(
    notice_path: Path,
    *,
    allow_msys2_package_files: bool = False,
) -> bool:
    if any(
        path.is_file()
        and path.stat().st_size > 0
        and looks_like_license_file(path)
        for path in notice_path.rglob("*")
    ):
        return True
    if not allow_msys2_package_files:
        return False

    # MSYS2 packages may install valid license texts with upstream-specific
    # names such as FreeType's FTL.TXT. stage_package_licenses() copies only
    # package-owned files from mingw64/share/licenses/ into this directory.
    # Trust that package-defined location without weakening filename checks for
    # DinoX, custom components, Go modules or Google/libwebrtc.
    installed_files = notice_path / "files"
    return installed_files.is_dir() and any(
        path.is_file() and path.stat().st_size > 0
        for path in installed_files.rglob("*")
    )


def source_material_metadata_matches(
    metadata_path: Path,
    package: PackageMetadata,
    source_url: str,
    archive: Path,
) -> bool:
    if not metadata_path.is_file() or not archive.is_file():
        return False
    try:
        metadata = parse_key_value_file(metadata_path)
    except (InventoryError, OSError, UnicodeError):
        return False
    return (
        metadata.get("base_package") == package.base
        and metadata.get("version") == package.version
        and metadata.get("source_url") == source_url
        and metadata.get("sha256") == sha256_file(archive)
    )


def prepare_msys2_source_license_material(
    package: PackageMetadata,
    vendor_root: Path,
    msys_root: Path,
) -> Path:
    for value, label in (
        (package.base, "base package"),
        (package.version, "package version"),
    ):
        if not re.fullmatch(r"[A-Za-z0-9@._+~:-]+", value):
            fail(f"unsafe MSYS2 {label}: {value!r}")

    archive_name = f"{package.base}-{package.version}.src.tar.zst"
    source_url = f"https://mirror.msys2.org/mingw/sources/{archive_name}"
    signature_url = source_url + ".sig"
    cache_root = vendor_root / "windows-msys2-source-cache"
    archive = cache_root / archive_name
    signature = cache_root / f"{archive_name}.sig"
    material_root = (
        vendor_root
        / "windows-msys2-license-material"
        / f"{package.base}-{package.version}"
    )
    metadata_path = material_root / "METADATA"
    files_root = material_root / "files"

    download_file(source_url, archive)
    download_file(signature_url, signature)
    keyring = msys_root / "etc/pacman.d/gnupg/pubring.gpg"
    if not keyring.is_file():
        fail(f"MSYS2 package-signing keyring missing: {keyring}")
    if not verify_detached_signature(archive, signature, keyring):
        print(f"Replacing invalid cached MSYS2 source material: {archive_name}")
        archive.unlink(missing_ok=True)
        signature.unlink(missing_ok=True)
        download_file(source_url, archive)
        download_file(signature_url, signature)
        if not verify_detached_signature(archive, signature, keyring):
            fail(f"MSYS2 source signature verification failed: {archive_name}")
    if source_material_metadata_matches(
        metadata_path, package, source_url, archive
    ) and any(
        path.is_file() and path.stat().st_size > 0
        for path in files_root.rglob("*")
    ):
        return material_root

    with tempfile.TemporaryDirectory(
        prefix=f"dinox-{package.base}-licenses-",
        dir=vendor_root,
    ) as temporary_text:
        temporary = Path(temporary_text)
        outer = temporary / "outer"
        extract_archive(archive, outer)
        verify_msys2_source_identity(outer, package)
        extraction_roots = [outer]
        extraction_roots.extend(
            materialize_bare_git_repositories(outer, temporary)
        )
        seen_archives: set[tuple[str, str]] = set()
        for _depth in range(2):
            candidates = [
                path
                for root in extraction_roots
                for path in root.rglob("*")
                if path.is_file() and looks_like_source_archive(path)
            ]
            new_roots: list[Path] = []
            for nested in candidates:
                identity = (str(nested), sha256_file(nested))
                if identity in seen_archives:
                    continue
                seen_archives.add(identity)
                nested_root = temporary / f"nested-{len(seen_archives):04d}"
                try:
                    extract_archive(nested, nested_root)
                except InventoryError:
                    # A source package may carry a non-tar ZIP. MSYS2's tar
                    # handles the formats used by the release baseline; an
                    # unsupported archive is ignored only if other verified
                    # license material is actually found below.
                    shutil.rmtree(nested_root, ignore_errors=True)
                    continue
                new_roots.append(nested_root)
            if not new_roots:
                break
            extraction_roots.extend(new_roots)

        license_files: list[tuple[int, Path, Path]] = []
        for root_number, root in enumerate(extraction_roots):
            for path in sorted(root.rglob("*")):
                if (
                    path.is_file()
                    and path.stat().st_size > 0
                    and looks_like_license_file(path)
                ):
                    license_files.append((root_number, root, path))
        if not license_files:
            fail(
                "signed MSYS2 source package contains no discoverable "
                f"license/notice files: {archive_name}"
            )

        replacement = temporary / "material"
        replacement_files = replacement / "files"
        for root_number, root, source in license_files:
            relative = source.relative_to(root)
            target = (
                replacement_files
                / f"source-tree-{root_number:04d}"
                / relative
            )
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        archive_sha256 = sha256_file(archive)
        (replacement / "METADATA").write_text(
            "\n".join(
                (
                    f"base_package={package.base}",
                    f"version={package.version}",
                    f"source_archive={archive_name}",
                    f"source_url={source_url}",
                    f"signature_url={signature_url}",
                    "signature_keyring=MSYS2 pacman keyring",
                    f"sha256={archive_sha256}",
                    f"license_files={len(license_files)}",
                    "",
                )
            ),
            encoding="utf-8",
            newline="\n",
        )
        shutil.rmtree(material_root, ignore_errors=True)
        material_root.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(replacement), str(material_root))
    return material_root


def package_source_reference(package: PackageMetadata) -> str:
    return (
        "https://mirror.msys2.org/mingw/sources/"
        f"{package.base}-{package.version}.src.tar.zst"
    )


def stage_package_licenses(
    msys_root: Path,
    vendor_root: Path,
    license_root: Path,
    package: PackageMetadata,
) -> Component:
    if not package.licenses:
        fail(f"MSYS2 package has no declared license metadata: {package.name}")
    destination_relative = Path("msys2") / package.name
    destination = license_root / destination_relative
    destination.mkdir(parents=True, exist_ok=True)

    copied = 0
    for relative_text in package.files:
        normalized = relative_text.replace("\\", "/")
        if "/share/licenses/" not in f"/{normalized}":
            continue
        source = msys_root / safe_relative_path(normalized)
        if not source.is_file() or source.stat().st_size <= 0:
            continue
        marker = normalized.index("share/licenses/") + len("share/licenses/")
        license_relative = safe_relative_path(normalized[marker:])
        target = destination / "files" / license_relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        copied += 1

    source_material_files = 0
    if copied == 0:
        source_material = prepare_msys2_source_license_material(
            package, vendor_root, msys_root
        )
        copy_nonempty_tree(
            source_material / "files",
            destination / "source-package-files",
        )
        shutil.copy2(source_material / "METADATA", destination / "SOURCE.txt")
        source_material_files = sum(
            1
            for path in (source_material / "files").rglob("*")
            if path.is_file() and path.stat().st_size > 0
        )
        if source_material_files == 0:
            fail(
                "signed MSYS2 source material supplied no license text: "
                f"{package.name}"
            )

    package_text = [
        f"Package: {package.name}",
        f"Version: {package.version}",
        f"Declared license metadata: {', '.join(package.licenses)}",
        f"MSYS2 package reference: https://packages.msys2.org/packages/{package.name}",
        f"Exact signed source-only package: {package_source_reference(package)}",
        f"Source signature: {package_source_reference(package)}.sig",
    ]
    if package.url:
        package_text.append(f"Upstream: {package.url}")
    package_text.append(f"Package-installed license files copied: {copied}")
    package_text.append(
        f"Signed source-package license files copied: {source_material_files}"
    )
    (destination / "PACKAGE.txt").write_text(
        "\n".join(package_text) + "\n", encoding="utf-8", newline="\n"
    )
    return Component(
        origin="msys2-package",
        name=package.name,
        version=package.version,
        declared_license=", ".join(package.licenses),
        source_reference=package_source_reference(package),
        notice_path=(
            Path("share/licenses/dinox") / destination_relative
        ).as_posix(),
    )


def runtime_asset_files(dist_root: Path) -> list[Path]:
    """Return non-PE runtime assets, including the matched vision package."""
    prefixes = (
        "etc/fonts/",
        "share/fonts/",
        "share/glib-2.0/schemas/",
        "share/icons/",
        "share/locale/",
        "share/tor/",
        "dinox-vision-models/",
        "dinox-vision-licenses/",
    )
    exact_paths = {
        "ca-bundle.crt",
        "ssl/certs/ca-bundle.crt",
        "dinox-vision-runtime-manifest.json",
        "dinox-vision-SHA256SUMS",
    }
    result: list[Path] = []
    for path in dist_root.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(dist_root).as_posix()
        if (
            relative in exact_paths
            or any(relative.startswith(prefix) for prefix in prefixes)
            or path.suffix.lower() == ".tflite"
        ):
            if (
                relative not in GENERATED_RUNTIME_ASSET_PATHS
                and not has_pe_signature(path)
            ):
                result.append(path)
    return sorted(result, key=lambda path: path.relative_to(dist_root).as_posix())


def owned_msys2_asset_package(
    artifact: Path,
    relative: str,
    mingw_root: Path,
    msys_root: Path,
    owners: dict[str, str],
) -> str | None:
    candidates = [mingw_root / relative, msys_root / relative]
    if relative in {"ca-bundle.crt", "ssl/certs/ca-bundle.crt"}:
        candidates = [
            mingw_root / "ssl/certs/ca-bundle.crt",
            mingw_root / "etc/ssl/certs/ca-bundle.crt",
            msys_root / "etc/ssl/certs/ca-bundle.crt",
            msys_root / "usr/ssl/certs/ca-bundle.crt",
            mingw_root / "ssl/cert.pem",
        ]
    artifact_hash = sha256_file(artifact)
    for source in candidates:
        if (
            not source.is_file()
            or source.stat().st_size != artifact.stat().st_size
            or sha256_file(source) != artifact_hash
        ):
            continue
        try:
            package_path = source.resolve().relative_to(msys_root.resolve()).as_posix()
        except ValueError:
            continue
        owner = owners.get(package_path)
        if owner:
            return owner
    return None


def classify_runtime_assets(
    project_root: Path,
    dist_root: Path,
    build_root: Path,
    mingw_root: Path,
    msys_root: Path,
    owners: dict[str, str],
    project_component: Component,
    vision_assets: dict[str, Component],
) -> tuple[list[tuple[str, ...]], set[str]]:
    assets = runtime_asset_files(dist_root)
    wanted_names = {path.name.lower() for path in assets}
    project_index = relevant_hash_index(
        project_root,
        wanted_names,
        excluded_roots=(
            project_root / ".git",
            build_root,
            dist_root,
        ),
    )
    records: list[tuple[str, ...]] = []
    used_packages: set[str] = set()
    unresolved: list[str] = []
    deferred: list[tuple[str, str, str]] = []

    for artifact in assets:
        relative = artifact.relative_to(dist_root).as_posix()
        checksum = sha256_file(artifact)
        if relative in vision_assets:
            component = vision_assets[relative]
            records.append((
                relative, checksum, component.origin, component.name, component.version,
                component.declared_license, component.source_reference, component.notice_path,
            ))
            continue
        if path_is_vision_asset(relative) or artifact.suffix.lower() == ".tflite":
            fail(f"vision runtime asset has no matched producer attribution: {relative}")
        package_name = owned_msys2_asset_package(
            artifact, relative, mingw_root, msys_root, owners
        )
        if package_name is not None:
            used_packages.add(package_name)
            deferred.append((relative, checksum, package_name))
            continue
        project_matches = project_index.get((artifact.name.lower(), checksum), [])
        if project_matches:
            records.append(
                (
                    relative,
                    checksum,
                    project_component.origin,
                    project_component.name,
                    project_component.version,
                    project_component.declared_license,
                    project_component.source_reference,
                    project_component.notice_path,
                )
            )
            continue
        unresolved.append(relative)

    if unresolved:
        fail(
            "unclassified bundled Windows runtime assets:\n  "
            + "\n  ".join(sorted(unresolved))
        )
    records.extend(
        (relative, checksum, "msys2-package", package_name)
        for relative, checksum, package_name in deferred
    )
    return records, used_packages


def path_is_vision_asset(relative: str) -> bool:
    return relative.startswith(("dinox-vision-models/", "dinox-vision-licenses/")) or relative in {
        "dinox-vision-runtime-manifest.json", "dinox-vision-SHA256SUMS",
    }


def vision_source_root(relative: str) -> str | None:
    parts = safe_relative_path(relative).parts
    if len(parts) >= 3 and parts[0] == "third_party":
        return Path(*parts[:2]).as_posix()
    if len(parts) >= 4 and parts[:2] == ("buildtools", "third_party"):
        return Path(*parts[:3]).as_posix()
    return None


def vision_components(
    dist_root: Path, *, stage_notices: bool,
) -> tuple[Component | None, dict[str, Component], list[Component]]:
    """Attribute only source/license evidence from the validated producer package."""
    manifest_path = dist_root / "dinox-vision-runtime-manifest.json"
    wrapper_manifest = dist_root / "share/licenses/dinox/google-libwebrtc/manifest.json"
    wrapper = json.loads(wrapper_manifest.read_text(encoding="utf-8"))
    required = int(wrapper.get("wrapper_abi", 0)) >= 40
    present = any(path_is_vision_asset(path.relative_to(dist_root).as_posix())
                  or path.name.casefold() == "dinox-vision-worker.exe"
                  or path.suffix.lower() == ".tflite" for path in dist_root.rglob("*") if path.is_file())
    if not required and not present:
        return None, {}, []
    checker = Path(__file__).resolve().with_name("check-vision-runtime.py")
    run_command([sys.executable, str(checker), "--base", str(dist_root), "--platform", "windows"])
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    record = manifest["build_manifests"][0]
    payload_id = manifest["payload_id"]
    source_files = manifest["source_files"]
    dependencies = record["dependency_provenance"]
    reachable = record["reachable_source_files_sha256"]
    if not isinstance(reachable, dict) or not reachable or len(reachable) > 100000:
        fail("vision producer has no bounded reachable source hash inventory")
    for path, checksum in reachable.items():
        safe_relative_path(path)
        if not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
            fail(f"invalid vision producer compiled source hash: {path}")
    licenses = record["licenses"]["gn_source_components"]
    grouped: dict[str, list[dict]] = defaultdict(list)
    component_roots: dict[str, set[str]] = defaultdict(set)
    for item in licenses:
        name = item["component"]
        if not re.fullmatch(r"[A-Za-z0-9_.+\-]+", name):
            fail(f"unsafe vision source component: {name!r}")
        source_root = vision_source_root(item["source_path"])
        if source_root is None or Path(source_root).name != name:
            fail(f"vision original license source is outside its declared component: {name}")
        if reachable.get(item["source_path"]) != item["license_sha256"]:
            fail(f"vision original license lacks exact reachable source hash evidence: {name}")
        component_roots[name].add(source_root)
        grouped[name].append(item)
    if not {"tflite", "xnnpack", "boringssl", "pthreadpool"} <= set(grouped):
        fail("Windows vision worker lacks TensorFlow, XNNPACK, BoringSSL or pthreadpool original license attribution")
    reachable_roots = {source_root for path in reachable if (source_root := vision_source_root(path)) is not None}
    licensed_roots = set().union(*component_roots.values())
    missing_roots = sorted(reachable_roots - licensed_roots)
    if missing_roots:
        fail("Windows vision worker has unattributed reachable source roots: " + ", ".join(missing_roots))
    notice_root = dist_root / "share/licenses/dinox/vision-runtime"
    if stage_notices:
        shutil.rmtree(notice_root, ignore_errors=True)
        notice_root.mkdir(parents=True)
        shutil.copyfile(manifest_path, notice_root / manifest_path.name)
        shutil.copyfile(dist_root / "dinox-vision-SHA256SUMS", notice_root / "dinox-vision-SHA256SUMS")
    else:
        for name in (manifest_path.name, "dinox-vision-SHA256SUMS"):
            copied = notice_root / name
            if not copied.is_file() or sha256_file(copied) != sha256_file(dist_root / name):
                fail("Windows vision notice manifest/checksums differ from the installed producer files")

    def component(name: str, version: str, declared: str, reference: str,
                  texts: list[tuple[str, str]], sources: dict) -> Component:
        destination = notice_root / name
        evidence = {"component": name, "version": version, "source_reference": reference,
                    "source_files_sha256": sources, "original_licenses": dict(texts)}
        if stage_notices:
            destination.mkdir(parents=True)
            (destination / "SOURCE.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        elif not (destination / "SOURCE.json").is_file() or json.loads((destination / "SOURCE.json").read_text(encoding="utf-8")) != evidence:
            fail(f"Windows vision original source evidence differs: {name}")
        for number, (relative, checksum) in enumerate(texts):
            original = dist_root / safe_relative_path(relative)
            if not original.is_file() or sha256_file(original) != checksum:
                fail(f"Windows vision original license SHA-256 mismatch: {relative}")
            copied = destination / f"LICENSE-{number}.txt"
            if stage_notices:
                shutil.copyfile(original, copied)
            elif not copied.is_file() or sha256_file(copied) != checksum:
                fail(f"Windows vision inventoried original license differs: {name}")
        return Component("dinox-vision-producer", name, version, declared, reference,
                         destination.relative_to(dist_root).as_posix())

    project_text = "dinox-vision-licenses/PROJECT_LICENSE"
    project_sha = source_files["licenses/PROJECT_LICENSE"]["sha256"]
    own_sources = {name: item["sha256"] for name, item in source_files.items()
                   if not name.startswith(("licenses/", "models/", "third_party/"))}
    worker = component("dinox-vision-worker", payload_id, "GPL-3.0-or-later",
                       f"producer payload SHA256={payload_id}; original source hashes in SOURCE.json",
                       [(project_text, project_sha)], own_sources)
    assets = {"dinox-vision-runtime-manifest.json": worker, "dinox-vision-SHA256SUMS": worker,
              project_text: worker}
    static_components = []
    aliases = {"tflite": "tensorflow"}
    for name, items in sorted(grouped.items()):
        dependency = aliases.get(name, name)
        revision = dependencies.get(dependency, {}).get("head")
        sources = {path: checksum for path, checksum in reachable.items()
                   if any(path.startswith(source_root + "/") for source_root in component_roots[name])}
        if not sources:
            fail(f"vision GN component has no compiled source hash evidence: {name}")
        snapshot = hashlib.sha256(json.dumps(sources, sort_keys=True).encode()).hexdigest()
        version = revision or f"source-snapshot-sha256:{snapshot}"
        reference = (f"producer dependency {dependency}={revision or 'GN source snapshot'}; "
                     f"compiled_sources_sha256={snapshot}; WebRTC pin={manifest['pins']['webrtc'][1]}; "
                     "original source and license hashes in SOURCE.json")
        texts = [("dinox-vision-licenses/" + safe_relative_path(item["bundle_path"]).as_posix(),
                  item["license_sha256"]) for item in items]
        source_evidence = dict(sources)
        for item in items:
            source_evidence[item["source_path"]] = item["license_sha256"]
        # The producer supplies original texts, not an SPDX guess. Every GN
        # component requires its own proven text/hash and compiled source set.
        declared = "Original source license texts; SHA256=" + ",".join(sha for _, sha in texts)
        entry = component("vision-" + name, version, declared, reference, texts, source_evidence)
        static_components.append(entry)
        for relative, _ in texts:
            assets[relative] = entry
    model_text = "dinox-vision-licenses/MODEL_AND_CUSTOM_OP_LICENSE"
    model_sha = source_files["licenses/MODEL_AND_CUSTOM_OP_LICENSE"]["sha256"]
    custom_sources = {name: item["sha256"] for name, item in source_files.items()
                      if name.startswith("third_party/mediapipe_cpu/")}
    if not custom_sources:
        fail("vision custom CPU operation has no producer source hashes")
    custom = component("vision-mediapipe-custom-cpu", manifest["mediapipe_custom_op_revision"],
                       "Apache-2.0", f"MediaPipe pin={manifest['mediapipe_custom_op_revision']}; original source hashes in SOURCE.json",
                       [(model_text, model_sha)], custom_sources)
    static_components.append(custom)
    assets[model_text] = custom
    for name, metadata in sorted(manifest["models"].items()):
        installed = name.replace("blaze-face-short-range", "blaze_face_short_range")
        relative = "dinox-vision-models/" + installed
        entry = component("vision-model-" + installed.removesuffix(".tflite"), metadata["sha256"],
                          metadata["license"], f"{metadata['url']}; model SHA256={metadata['sha256']}; original license SHA256={model_sha}",
                          [(model_text, model_sha)], {relative: metadata["sha256"]})
        assets[relative] = entry
    for path in runtime_asset_files(dist_root):
        relative = path.relative_to(dist_root).as_posix()
        if path_is_vision_asset(relative) and relative not in assets:
            fail(f"unattributed installed vision file: {relative}")
    return worker, assets, static_components


def markdown_cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def write_notices(license_root: Path, components: list[Component]) -> None:
    lines = [
        "# DinoX Windows third-party notices",
        "",
        "This portable distribution contains dynamically bundled executables and "
        "libraries under their respective licenses. The machine-readable "
        f"`{INVENTORY_NAME}` maps every packaged EXE and DLL to the component, "
        "exact version, SHA-256 digest, source reference and notice directory.",
        f"`{STATIC_INVENTORY_NAME}` records third-party components linked into a "
        "DinoX binary instead of shipped as a separate DLL.",
        f"`{ASSET_INVENTORY_NAME}` maps bundled themes, fonts, schemas, "
        "certificates and other runtime assets to DinoX or their MSYS2 package.",
        "",
        "Large source archives are deliberately not embedded in the portable "
        "Windows package.",
        "",
        "| Component | Version | Origin | Declared license metadata | Source | Notices |",
        "|---|---|---|---|---|---|",
    ]
    unique = {
        (
            item.origin,
            item.name,
            item.version,
            item.declared_license,
            item.source_reference,
            item.notice_path,
        ): item
        for item in components
    }
    for item in sorted(unique.values(), key=lambda value: (value.origin, value.name)):
        lines.append(
            "| "
            + " | ".join(
                markdown_cell(value)
                for value in (
                    item.name,
                    item.version,
                    item.origin,
                    item.declared_license,
                    item.source_reference,
                    item.notice_path,
                )
            )
            + " |"
        )
    (license_root / NOTICE_NAME).write_text(
        "\n".join(lines) + "\n", encoding="utf-8", newline="\n"
    )


def write_license_file_inventory(license_root: Path) -> None:
    inventory_path = license_root / LICENSE_FILE_INVENTORY_NAME
    inventory_path.unlink(missing_ok=True)
    files = sorted(
        (
            path
            for path in license_root.rglob("*")
            if path.is_file() and path != inventory_path
        ),
        key=lambda path: path.relative_to(license_root).as_posix(),
    )
    with inventory_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, dialect="excel-tab", lineterminator="\n")
        writer.writerow(LICENSE_FILE_INVENTORY_HEADER)
        for path in files:
            writer.writerow(
                (
                    path.relative_to(license_root).as_posix(),
                    sha256_file(path),
                    path.stat().st_size,
                )
            )


def stage(args: argparse.Namespace) -> None:
    project_root = args.project.resolve()
    dist_root = args.dist.resolve()
    build_root = args.build.resolve()
    vendor_root = args.vendor_root.resolve()
    mingw_root = args.mingw_root.resolve()
    msys_root = args.msys_root.resolve()
    license_root = dist_root / "share/licenses/dinox"
    if not dist_root.is_dir() or not build_root.is_dir():
        fail("Windows dist and build directories must exist before license staging")

    artifacts = pe_files(dist_root)
    if not artifacts:
        fail(f"no PE files found in Windows distribution: {dist_root}")
    wanted_names = {path.name.lower() for path in artifacts}

    runtime_root = args.webrtc_root.resolve()
    tor_source = args.tor.resolve()
    openssl_source = args.openssl.resolve()
    lyrebird_path = args.lyrebird.resolve()
    source_indices = {
        "private-gio": relevant_hash_index(vendor_root / "glib-networking-2.80.1-dinox/lib/gio", wanted_names),
        "webrtc": relevant_hash_index(runtime_root, wanted_names),
        "lyrebird": relevant_hash_index(lyrebird_path.parent, wanted_names),
        "build": relevant_hash_index(build_root, wanted_names),
        "mingw-bin": relevant_hash_index(mingw_root / "bin", wanted_names),
        "mingw-gstreamer": relevant_hash_index(
            mingw_root / "lib/gstreamer-1.0", wanted_names
        ),
        "mingw-gio": relevant_hash_index(mingw_root / "lib/gio", wanted_names),
        "mingw-pixbuf": relevant_hash_index(
            mingw_root / "lib/gdk-pixbuf-2.0", wanted_names
        ),
    }
    packages, owners = load_package_database(msys_root)
    tor_package_name = validate_manifest_transformed_msys2_executable(
        project_root,
        dist_root,
        mingw_root,
        tor_source,
        "bin/tor.exe",
        "bin/tor.exe",
        TOR_PACKAGE_NAME,
        TOR_PACKAGE_VERSION,
        packages,
        owners,
        allow_non_windows_fixture=getattr(
            args, "_allow_non_windows_transform_fixture", False
        ),
    )
    openssl_package_name = validate_manifest_transformed_msys2_executable(
        project_root,
        dist_root,
        mingw_root,
        openssl_source,
        "bin/openssl.exe",
        "bin/openssl.exe",
        OPENSSL_PACKAGE_NAME,
        None,
        packages,
        owners,
        allow_non_windows_fixture=getattr(
            args, "_allow_non_windows_transform_fixture", False
        ),
    )

    shutil.rmtree(license_root / "dinox", ignore_errors=True)
    shutil.rmtree(license_root / "custom", ignore_errors=True)
    shutil.rmtree(license_root / "msys2", ignore_errors=True)
    for generated in (
        license_root / INVENTORY_NAME,
        license_root / ASSET_INVENTORY_NAME,
        license_root / STATIC_INVENTORY_NAME,
        license_root / LICENSE_FILE_INVENTORY_NAME,
        license_root / NOTICE_NAME,
    ):
        generated.unlink(missing_ok=True)
    license_root.mkdir(parents=True, exist_ok=True)
    stage_project_licenses(project_root, license_root)

    version = project_version(project_root)
    commit = project_commit(dist_root)
    project_component = Component(
        origin="dinox-source",
        name="dinox",
        version=version,
        declared_license="GPL-3.0-or-later",
        source_reference=f"https://git.dinox.im/dinoxim/dinox/commit/{commit}",
        notice_path="share/licenses/dinox/dinox",
    )
    utf8_manifest_transform_component = Component(
        origin="dinox-source",
        name="dinox-windows-utf8-manifest-transform",
        version=version,
        declared_license="GPL-3.0-or-later",
        source_reference=(
            "https://git.dinox.im/dinoxim/dinox/src/commit/"
            f"{commit}/scripts/embed-windows-utf8-manifest.py"
        ),
        notice_path="share/licenses/dinox/dinox",
    )

    manifest_path = license_root / "google-libwebrtc/manifest.json"
    if not manifest_path.is_file():
        fail(f"Google/libwebrtc manifest missing: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    webrtc_commit = str(manifest.get("webrtc_commit", ""))
    if not re.fullmatch(r"[0-9a-f]{40}", webrtc_commit):
        fail("Google/libwebrtc manifest has no valid webrtc_commit")
    webrtc_component = Component(
        origin="google-libwebrtc-runtime",
        name="google-libwebrtc",
        version=f"M{manifest.get('webrtc_milestone', 'unknown')}",
        declared_license="See LICENSE, LICENSE.md and PATENTS",
        source_reference=f"https://webrtc.googlesource.com/src/+/{webrtc_commit}",
        notice_path="share/licenses/dinox/google-libwebrtc",
    )
    vision_worker, vision_assets, vision_static = vision_components(dist_root, stage_notices=True)
    hardware_component = None
    hardware_manifest = license_root / "google-libwebrtc/FFMPEG-WINDOWS-HARDWARE.json"
    if hardware_manifest.is_file():
        hardware_metadata = json.loads(hardware_manifest.read_text(encoding="utf-8"))
        for relative in (
            "FFMPEG-LICENSE", "CODEC-SOURCES.md",
            "sources/ffmpeg-mf-dynamic-bitrate.patch",
        ):
            source = hardware_manifest.parent / relative
            if not source.is_file() or source.stat().st_size == 0:
                fail(f"private hardware FFmpeg license/source file missing: {relative}")
        hardware_component = Component(
            origin="google-libwebrtc-hardware-provider",
            name="ffmpeg-hardware-codecs",
            version=str(hardware_metadata["ffmpeg_version"]),
            declared_license="LGPL-2.1-or-later",
            source_reference=(
                "https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz; "
                "bundled patch: sources/ffmpeg-mf-dynamic-bitrate.patch"
            ),
            notice_path="share/licenses/dinox/google-libwebrtc",
        )
    custom_components = {
        name: load_custom_component(vendor_root, license_root, name)
        for name in sorted(CUSTOM_COMPONENTS)
    }
    lyrebird_metadata = parse_key_value_file(
        vendor_root
        / "windows-license-material"
        / str(CUSTOM_COMPONENTS["lyrebird"]["directory"])
        / "METADATA"
    )
    for key in (
        "go_version",
        "go_license_expression",
        "go_source_url",
        "go_source_sha256",
    ):
        if not lyrebird_metadata.get(key):
            fail(f"Lyrebird license metadata is missing {key}")
    if not re.fullmatch(r"[0-9a-f]{64}", lyrebird_metadata["go_source_sha256"]):
        fail("Lyrebird license metadata has an invalid Go source SHA-256")
    lyrebird_build_metadata_path = lyrebird_path.parent / "BUILD-METADATA"
    if not lyrebird_build_metadata_path.is_file():
        fail(f"Lyrebird build metadata missing: {lyrebird_build_metadata_path}")
    lyrebird_build_metadata = parse_key_value_file(lyrebird_build_metadata_path)
    expected_lyrebird_build_metadata = {
        "component": "lyrebird",
        "version": str(CUSTOM_COMPONENTS["lyrebird"]["version"]),
        "source_sha256": str(CUSTOM_COMPONENTS["lyrebird"]["checksum"]),
        "go_version": lyrebird_metadata["go_version"],
        "binary_sha256": sha256_file(lyrebird_path),
    }
    for key, value in expected_lyrebird_build_metadata.items():
        if lyrebird_build_metadata.get(key) != value:
            fail(
                f"Lyrebird build metadata {key}="
                f"{lyrebird_build_metadata.get(key)!r}, expected {value!r}"
            )
    go_component = Component(
        origin="toolchain-runtime",
        name="go-runtime",
        version=lyrebird_metadata["go_version"],
        declared_license=lyrebird_metadata["go_license_expression"],
        source_reference=lyrebird_metadata["go_source_url"],
        notice_path=custom_components["lyrebird"].notice_path,
    )
    go_module_components = load_lyrebird_go_modules(
        vendor_root, custom_components["lyrebird"]
    )

    records: list[tuple[str, ...]] = []
    used_packages: set[str] = set()
    record_components: list[Component] = [
        project_component,
        utf8_manifest_transform_component,
        webrtc_component,
    ]
    record_components.extend(custom_components.values())
    if vision_worker is not None:
        record_components.append(vision_worker)
        record_components.extend(vision_assets.values())
        record_components.extend(vision_static)
    if hardware_component is not None:
        record_components.append(hardware_component)
    record_components.append(go_component)
    record_components.extend(go_module_components)
    unresolved: list[str] = []

    for artifact in artifacts:
        relative = artifact.relative_to(dist_root).as_posix()
        checksum = sha256_file(artifact)
        key = (artifact.name.lower(), checksum)
        matches = {
            label: paths
            for label, index in source_indices.items()
            if (paths := index.get(key))
        }
        component: Component | None = None
        package_names: set[str] = set()
        package_name = ""

        if relative.casefold() == "bin/tor.exe":
            package_name = tor_package_name
            package_names.add(package_name)
            used_packages.add(package_name)
        elif relative.casefold() == "bin/openssl.exe":
            package_name = openssl_package_name
            package_names.add(package_name)
            used_packages.add(package_name)
        elif artifact.name.lower() in {
            "dinox-google-webrtc.dll",
            "dinox-webrtc-worker.exe",
        }:
            component = project_component
        elif relative.casefold() == "lib/gio/modules/libgiognutls.dll":
            if not matches.get("private-gio"):
                fail("GIO TLS module does not match the private Unicode-safe runtime")
            component = custom_components["glib-networking-dinox"]
        elif artifact.name.casefold() == "dinox-vision-worker.exe":
            if relative != "dinox-vision-worker.exe" or vision_worker is None or not matches.get("webrtc"):
                fail("Windows vision worker has no exact matched runtime producer source")
            component = vision_worker
        elif matches.get("webrtc") and artifact.name.lower() in {
            "avcodec-dinox-hw-62.dll", "avutil-dinox-hw-60.dll",
        }:
            if hardware_component is None:
                fail("private hardware FFmpeg DLLs lack their license/source manifest")
            component = hardware_component
        elif matches.get("webrtc"):
            component = webrtc_component
        elif (
            matches.get("lyrebird")
            and any(path.resolve() == lyrebird_path for path in matches["lyrebird"])
        ):
            component = custom_components["lyrebird"]
        elif matches.get("build"):
            component = project_component
        else:
            mingw_sources = [
                path
                for label, paths in matches.items()
                if label.startswith("mingw-")
                for path in paths
            ]
            custom_omemo = [
                path
                for path in mingw_sources
                if path.parent.resolve() == (mingw_root / "bin").resolve()
                and path.name.lower() in {"libomemo-c.dll", "libomemo-c-0.dll"}
            ]
            for source in mingw_sources:
                relative_source = source.relative_to(mingw_root).as_posix()
                owner = owners.get(f"mingw64/{relative_source}")
                if owner:
                    package_names.add(owner)
            if custom_omemo and not package_names:
                component = custom_components["libomemo-c"]
            elif len(package_names) == 1:
                package_name = next(iter(package_names))
                used_packages.add(package_name)
            elif len(package_names) > 1:
                unresolved.append(
                    f"{relative}: identical source candidates belong to "
                    + ", ".join(sorted(package_names))
                )
            else:
                unresolved.append(f"{relative}: no exact source/package match")

        if component is not None:
            records.append(
                (
                    relative,
                    checksum,
                    component.origin,
                    component.name,
                    component.version,
                    component.declared_license,
                    component.source_reference,
                    component.notice_path,
                )
            )
        elif len(package_names) == 1:
            # Package component staging is deferred until the used-package set
            # is complete, then the final metadata is filled below.
            records.append((relative, checksum, "msys2-package", package_name))

    if unresolved:
        fail(
            "unclassified Windows PE files:\n  "
            + "\n  ".join(sorted(unresolved))
        )

    asset_records, asset_packages = classify_runtime_assets(
        project_root,
        dist_root,
        build_root,
        mingw_root,
        msys_root,
        owners,
        project_component,
        vision_assets,
    )
    used_packages.update(asset_packages)
    package_components = {
        name: stage_package_licenses(
            msys_root, vendor_root, license_root, packages[name]
        )
        for name in sorted(used_packages)
    }
    complete_records: list[tuple[str, ...]] = []
    for record in records:
        if len(record) == len(INVENTORY_HEADER):
            complete_records.append(record)
            continue
        relative, checksum, _origin, package_name = record
        component = package_components[package_name]
        complete_records.append(
            (
                relative,
                checksum,
                component.origin,
                component.name,
                component.version,
                component.declared_license,
                component.source_reference,
                component.notice_path,
            )
        )
    record_components.extend(package_components.values())

    complete_asset_records: list[tuple[str, ...]] = []
    for record in asset_records:
        if len(record) == len(INVENTORY_HEADER):
            complete_asset_records.append(record)
            continue
        relative, checksum, _origin, package_name = record
        component = package_components[package_name]
        complete_asset_records.append(
            (
                relative,
                checksum,
                component.origin,
                component.name,
                component.version,
                component.declared_license,
                component.source_reference,
                component.notice_path,
            )
        )

    inventory_path = license_root / INVENTORY_NAME
    with inventory_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, dialect="excel-tab", lineterminator="\n")
        writer.writerow(INVENTORY_HEADER)
        writer.writerows(sorted(complete_records, key=lambda row: row[0].lower()))
    with (license_root / ASSET_INVENTORY_NAME).open(
        "w", encoding="utf-8", newline=""
    ) as handle:
        writer = csv.writer(handle, dialect="excel-tab", lineterminator="\n")
        writer.writerow(INVENTORY_HEADER)
        writer.writerows(
            sorted(complete_asset_records, key=lambda row: row[0].lower())
        )

    static_mappings = [
        ("dinox-google-webrtc.dll", webrtc_component),
        ("bin/openssl.exe", utf8_manifest_transform_component),
        ("bin/tor.exe", utf8_manifest_transform_component),
        ("bin/lyrebird.exe", go_component),
    ]
    static_mappings.extend(
        ("bin/lyrebird.exe", component)
        for component in go_module_components
    )
    static_mappings.extend(("dinox-vision-worker.exe", component) for component in vision_static)
    with (license_root / STATIC_INVENTORY_NAME).open(
        "w", encoding="utf-8", newline=""
    ) as handle:
        writer = csv.writer(handle, dialect="excel-tab", lineterminator="\n")
        writer.writerow(STATIC_INVENTORY_HEADER)
        for relative, component in static_mappings:
            artifact = dist_root / relative
            if not artifact.is_file():
                fail(f"{relative} is required for the static-component inventory")
            writer.writerow(
                (
                    relative,
                    sha256_file(artifact),
                    component.name,
                    component.version,
                    component.declared_license,
                    component.source_reference,
                    component.notice_path,
                )
            )
    write_notices(license_root, record_components)
    write_license_file_inventory(license_root)
    verify_distribution(dist_root)
    print(
        "Staged Windows license inventory: "
        f"{len(complete_records)} PE files, {len(complete_asset_records)} assets, "
        f"{len(package_components)} MSYS2 packages"
    )


def verify_distribution(dist_root: Path) -> None:
    dist_root = dist_root.resolve()
    license_root = dist_root / "share/licenses/dinox"
    vision_worker, vision_assets, vision_static = vision_components(dist_root, stage_notices=False)
    inventory_path = license_root / INVENTORY_NAME
    required = (
        license_root / "dinox/LICENSE",
        license_root / "dinox/NOTICE",
        license_root / "dinox/AUTHORS",
        license_root / "google-libwebrtc/LICENSE",
        license_root / "google-libwebrtc/LICENSE.md",
        license_root / "google-libwebrtc/PATENTS",
        license_root / "google-libwebrtc/manifest.json",
        inventory_path,
        license_root / ASSET_INVENTORY_NAME,
        license_root / STATIC_INVENTORY_NAME,
        license_root / LICENSE_FILE_INVENTORY_NAME,
        license_root / NOTICE_NAME,
    )
    for path in required:
        if not path.is_file() or path.stat().st_size <= 0:
            fail(f"required Windows license file missing or empty: {path}")

    total_size = 0
    for path in license_root.rglob("*"):
        if path.is_symlink():
            fail(f"symlink is not allowed in Windows license tree: {path}")
        if not path.is_file():
            continue
        size = path.stat().st_size
        total_size += size
        if size > MAX_LICENSE_FILE_BYTES:
            fail(
                f"Windows license file exceeds {MAX_LICENSE_FILE_BYTES} bytes: "
                f"{path.relative_to(dist_root)} ({size} bytes)"
            )
        lowered = path.name.lower()
        if any(lowered.endswith(suffix) for suffix in FORBIDDEN_ARCHIVE_SUFFIXES):
            fail(f"source/package archive is forbidden in Windows license tree: {path}")
    if total_size > MAX_LICENSE_TREE_BYTES:
        fail(
            f"Windows license tree exceeds {MAX_LICENSE_TREE_BYTES} bytes: "
            f"{total_size} bytes"
        )

    for path in dist_root.rglob("*"):
        relative = path.relative_to(dist_root)
        if path.is_symlink():
            fail(f"symlink is not allowed in portable Windows dist: {relative}")
        if not path.is_file() or license_root in path.parents:
            continue
        lowered = path.name.lower()
        if any(lowered.endswith(suffix) for suffix in FORBIDDEN_ARCHIVE_SUFFIXES):
            fail(f"source/package archive is forbidden in Windows dist: {relative}")
        if path.suffix.lower() in {".a", ".la", ".o", ".obj", ".pdb"}:
            fail(f"build-only file is forbidden in portable Windows dist: {relative}")
        if any(
            part.lower() in {".git", "__pycache__", "meson-private", "meson-logs"}
            for part in relative.parts
        ):
            fail(f"build/cache path is forbidden in portable Windows dist: {relative}")

    license_file_inventory_path = license_root / LICENSE_FILE_INVENTORY_NAME
    with license_file_inventory_path.open(
        "r", encoding="utf-8", newline=""
    ) as handle:
        reader = csv.reader(handle, dialect="excel-tab")
        try:
            license_file_header = tuple(next(reader))
        except StopIteration:
            fail(f"empty Windows license-file inventory: {license_file_inventory_path}")
        if license_file_header != LICENSE_FILE_INVENTORY_HEADER:
            fail(
                "unexpected Windows license-file inventory header: "
                f"{license_file_header!r}"
            )
        license_file_rows = list(reader)
    inventoried_license_files: set[str] = set()
    for line_number, row in enumerate(license_file_rows, start=2):
        if len(row) != len(LICENSE_FILE_INVENTORY_HEADER):
            fail(f"invalid license-file inventory row {line_number}")
        relative_text, expected_sha256, expected_size_text = row
        relative = safe_relative_path(relative_text)
        normalized = relative.as_posix()
        if normalized in inventoried_license_files:
            fail(f"duplicate Windows license-file inventory path: {normalized}")
        inventoried_license_files.add(normalized)
        path = license_root / relative
        if not path.is_file():
            fail(f"inventoried Windows license file is missing: {normalized}")
        try:
            expected_size = int(expected_size_text)
        except ValueError:
            fail(f"invalid license-file size in inventory: {normalized}")
        if expected_size <= 0 or path.stat().st_size != expected_size:
            fail(f"Windows license-file size mismatch: {normalized}")
        if (
            not re.fullmatch(r"[0-9a-f]{64}", expected_sha256)
            or sha256_file(path) != expected_sha256
        ):
            fail(f"Windows license-file SHA-256 mismatch: {normalized}")
    actual_license_files = {
        path.relative_to(license_root).as_posix()
        for path in license_root.rglob("*")
        if path.is_file() and path != license_file_inventory_path
    }
    if inventoried_license_files != actual_license_files:
        missing = sorted(actual_license_files - inventoried_license_files)
        extra = sorted(inventoried_license_files - actual_license_files)
        fail(
            "Windows license-file inventory coverage mismatch "
            f"(missing={missing!r}, extra={extra!r})"
        )

    with inventory_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.reader(handle, dialect="excel-tab")
        try:
            header = tuple(next(reader))
        except StopIteration:
            fail(f"empty Windows PE inventory: {inventory_path}")
        if header != INVENTORY_HEADER:
            fail(f"unexpected Windows PE inventory header: {header!r}")
        rows = list(reader)

    inventory_paths: set[str] = set()
    for line_number, row in enumerate(rows, start=2):
        if len(row) != len(INVENTORY_HEADER):
            fail(f"invalid inventory row {line_number}: expected 8 fields")
        (
            relative_text,
            expected_sha256,
            origin,
            component,
            version,
            declared_license,
            source_reference,
            notice_text,
        ) = row
        relative = safe_relative_path(relative_text)
        normalized = relative.as_posix()
        if normalized in inventory_paths:
            fail(f"duplicate Windows PE inventory path: {normalized}")
        inventory_paths.add(normalized)
        artifact = dist_root / relative
        if not artifact.is_file() or not has_pe_signature(artifact):
            fail(f"inventory path is not a packaged PE file: {normalized}")
        if not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
            fail(f"invalid SHA-256 in Windows PE inventory: {normalized}")
        if sha256_file(artifact) != expected_sha256:
            fail(f"Windows PE inventory SHA-256 mismatch: {normalized}")
        if not all((origin, component, version, declared_license, source_reference)):
            fail(f"incomplete component metadata in inventory: {normalized}")
        if normalized == "dinox-vision-worker.exe":
            expected = vision_worker
            if expected is None or tuple(row[2:]) != (
                expected.origin, expected.name, expected.version, expected.declared_license,
                expected.source_reference, expected.notice_path,
            ):
                fail("Windows PE inventory has no exact vision worker producer attribution")
        notice_relative = safe_relative_path(notice_text)
        notice_path = dist_root / notice_relative
        if not notice_path.is_dir():
            fail(f"inventory notice directory missing: {notice_text}")
        if not notice_directory_has_license_text(
            notice_path,
            allow_msys2_package_files=(origin == "msys2-package"),
        ):
            fail(f"inventory notice directory has no license text: {notice_text}")

    actual_paths = {
        path.relative_to(dist_root).as_posix() for path in pe_files(dist_root)
    }
    missing = sorted(actual_paths - inventory_paths)
    extra = sorted(inventory_paths - actual_paths)
    if missing or extra:
        details = []
        if missing:
            details.append("missing: " + ", ".join(missing))
        if extra:
            details.append("extra: " + ", ".join(extra))
        fail("Windows PE inventory coverage mismatch (" + "; ".join(details) + ")")
    if not rows:
        fail("Windows PE inventory contains no artifacts")

    asset_inventory_path = license_root / ASSET_INVENTORY_NAME
    with asset_inventory_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.reader(handle, dialect="excel-tab")
        try:
            asset_header = tuple(next(reader))
        except StopIteration:
            fail(f"empty Windows asset inventory: {asset_inventory_path}")
        if asset_header != INVENTORY_HEADER:
            fail(f"unexpected Windows asset inventory header: {asset_header!r}")
        asset_rows = list(reader)
    asset_paths: set[str] = set()
    for line_number, row in enumerate(asset_rows, start=2):
        if len(row) != len(INVENTORY_HEADER):
            fail(f"invalid asset inventory row {line_number}: expected 8 fields")
        (
            relative_text,
            expected_sha256,
            origin,
            component,
            version,
            declared_license,
            source_reference,
            notice_text,
        ) = row
        relative = safe_relative_path(relative_text)
        normalized = relative.as_posix()
        if normalized in asset_paths:
            fail(f"duplicate Windows asset inventory path: {normalized}")
        asset_paths.add(normalized)
        artifact = dist_root / relative
        if not artifact.is_file() or has_pe_signature(artifact):
            fail(f"asset inventory path is not a non-PE runtime asset: {normalized}")
        if (
            not re.fullmatch(r"[0-9a-f]{64}", expected_sha256)
            or sha256_file(artifact) != expected_sha256
        ):
            fail(f"Windows asset inventory SHA-256 mismatch: {normalized}")
        if not all((origin, component, version, declared_license, source_reference)):
            fail(f"incomplete component metadata in asset inventory: {normalized}")
        if expected := vision_assets.get(normalized):
            if tuple(row[2:]) != (expected.origin, expected.name, expected.version,
                                 expected.declared_license, expected.source_reference, expected.notice_path):
                fail(f"Windows asset inventory producer attribution differs: {normalized}")
        notice_path = dist_root / safe_relative_path(notice_text)
        if not notice_path.is_dir() or not notice_directory_has_license_text(
            notice_path,
            allow_msys2_package_files=(origin == "msys2-package"),
        ):
            fail(f"asset notice directory has no license text: {notice_text}")
    actual_asset_paths = {
        path.relative_to(dist_root).as_posix()
        for path in runtime_asset_files(dist_root)
    }
    if asset_paths != actual_asset_paths:
        missing = sorted(actual_asset_paths - asset_paths)
        extra = sorted(asset_paths - actual_asset_paths)
        fail(
            "Windows runtime-asset inventory coverage mismatch "
            f"(missing={missing!r}, extra={extra!r})"
        )
    if not asset_rows:
        fail("Windows asset inventory contains no runtime assets")

    static_inventory_path = license_root / STATIC_INVENTORY_NAME
    with static_inventory_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.reader(handle, dialect="excel-tab")
        try:
            static_header = tuple(next(reader))
        except StopIteration:
            fail(f"empty Windows static-component inventory: {static_inventory_path}")
        if static_header != STATIC_INVENTORY_HEADER:
            fail(
                "unexpected Windows static-component inventory header: "
                f"{static_header!r}"
            )
        static_rows = list(reader)
    if not static_rows:
        fail("Windows static-component inventory contains no components")
    static_pairs: set[tuple[str, str]] = set()
    for line_number, row in enumerate(static_rows, start=2):
        if len(row) != len(STATIC_INVENTORY_HEADER):
            fail(f"invalid static-component row {line_number}: expected 7 fields")
        (
            relative_text,
            expected_sha256,
            component,
            version,
            declared_license,
            source_reference,
            notice_text,
        ) = row
        relative = safe_relative_path(relative_text)
        artifact = dist_root / relative
        if not artifact.is_file() or not has_pe_signature(artifact):
            fail(f"static-component path is not a packaged PE file: {relative_text}")
        if sha256_file(artifact) != expected_sha256:
            fail(f"static-component SHA-256 mismatch: {relative_text}")
        if not all((component, version, declared_license, source_reference)):
            fail(f"incomplete static-component metadata: {relative_text}")
        if relative.as_posix() == "dinox-vision-worker.exe":
            expected = next((item for item in vision_static if item.name == component), None)
            if expected is None or tuple(row[2:]) != (expected.name, expected.version, expected.declared_license,
                                                     expected.source_reference, expected.notice_path):
                fail(f"Windows static-component producer attribution differs: {component}")
        pair = (relative.as_posix(), component)
        if pair in static_pairs:
            fail(f"duplicate Windows static-component mapping: {pair}")
        static_pairs.add(pair)
        notice_path = dist_root / safe_relative_path(notice_text)
        if not notice_path.is_dir() or not notice_directory_has_license_text(
            notice_path
        ):
            fail(f"static-component notice directory has no license text: {notice_text}")
    required_static_pairs = {
        ("dinox-google-webrtc.dll", "google-libwebrtc"),
        ("bin/lyrebird.exe", "go-runtime"),
    }
    required_static_pairs.update(("dinox-vision-worker.exe", component.name) for component in vision_static)
    missing_static_pairs = sorted(required_static_pairs - static_pairs)
    if missing_static_pairs:
        fail(
            "required Windows static-component mappings are missing: "
            + ", ".join(f"{path}->{component}" for path, component in missing_static_pairs)
        )
    go_module_pairs = {
        pair for pair in static_pairs if pair[1].startswith("go-module:")
    }
    if not go_module_pairs:
        fail("Windows static-component inventory has no Lyrebird Go modules")
    print(
        "OK: Windows license inventory "
        f"({len(rows)} PE files, {len(asset_rows)} assets, "
        f"{len(static_rows)} static components, "
        f"{total_size} license bytes)"
    )


def write_fake_package(
    msys_root: Path,
    name: str,
    version: str,
    files: list[str],
) -> None:
    package_dir = msys_root / f"var/lib/pacman/local/{name}-{version}"
    package_dir.mkdir(parents=True)
    (package_dir / "desc").write_text(
        "\n".join(
            (
                "%NAME%",
                name,
                "",
                "%VERSION%",
                version,
                "",
                "%LICENSE%",
                "MIT",
                "",
                "%URL%",
                "https://example.test/libfoo",
                "",
            )
        ),
        encoding="utf-8",
    )
    (package_dir / "files").write_text(
        "%FILES%\n" + "\n".join(files) + "\n", encoding="utf-8"
    )


def run_self_test() -> None:
    import threading
    from unittest.mock import patch

    # Use real subprocess pipes with non-UTF-8 diagnostics. Neither successful
    # nor failed signature verification may depend on a reader's text codec.
    subprocess_run = subprocess.run
    for code in (0, 1):
        reader_errors: list[BaseException] = []

        def verifier_fixture(command: list[str], **kwargs: object) -> subprocess.CompletedProcess:
            assert command[0] == "gpgv"
            return subprocess_run(
                [sys.executable, "-c", f"import os,sys;os.write(2,bytes([228]));sys.exit({code})"],
                **kwargs,
            )

        with patch.object(subprocess, "run", side_effect=verifier_fixture), patch.object(
            threading, "excepthook", side_effect=lambda args: reader_errors.append(args.exc_value)
        ):
            valid = verify_detached_signature(Path("archive"), Path("signature"), Path("keyring"))
        if valid != (code == 0) or reader_errors:
            fail(f"self-test failed to preserve binary gpgv diagnostics/exit status {code}")

    with tempfile.TemporaryDirectory(prefix="dinox-win-license-test-") as temp_text:
        temp = Path(temp_text)
        project = temp / "project"
        dist = project / "dist"
        build = project / "build"
        vendor = temp / "vendor"
        mingw = temp / "msys64/mingw64"
        msys = temp / "msys64"
        webrtc = vendor / "libwebrtc"
        tor = mingw / "bin/tor.exe"
        openssl = mingw / "bin/openssl.exe"
        lyrebird = vendor / "lyrebird-0.8.1/lyrebird.exe"
        for directory in (dist, build, mingw / "bin", webrtc / "bin", lyrebird.parent):
            directory.mkdir(parents=True, exist_ok=True)

        (project / "meson.build").write_text(
            "project('Dino', 'vala', version: '9.9.9')\n", encoding="utf-8"
        )
        (project / "scripts").mkdir()
        (project / "scripts/embed-windows-utf8-manifest.py").write_text(
            "# fixture helper\n", encoding="utf-8"
        )
        (project / "main/data").mkdir(parents=True)
        (project / "main/data/dinox.exe.manifest").write_bytes(
            UTF8_MANIFEST_MARKER
        )
        for filename in ("LICENSE", "NOTICE", "AUTHORS"):
            (project / filename).write_text(f"{filename} text\n", encoding="utf-8")
        (dist / "build-info.txt").write_text(
            "source_commit=" + "a" * 40 + "\nsource_dirty=false\n", encoding="utf-8"
        )

        def fake_pe(label: bytes) -> bytes:
            content = bytearray(128 + len(label))
            content[:2] = b"MZ"
            content[0x3C:0x40] = (64).to_bytes(4, byteorder="little")
            content[64:68] = b"PE\0\0"
            content[128:] = label
            return bytes(content)

        fixture_files = {
            vendor / "glib-networking-2.80.1-dinox/lib/gio/modules/libgiognutls.dll": fake_pe(b"private-gio"),
            build / "dinox.exe": fake_pe(b"project"),
            build / "main/dinox-backup-tar.exe": fake_pe(b"backup-helper"),
            build / "plugins/omemo.dll": fake_pe(b"omemo-plugin"),
            webrtc / "bin/dinox-google-webrtc.dll": fake_pe(b"webrtc-wrapper"),
            webrtc / "bin/dinox-webrtc-worker.exe": fake_pe(b"webrtc-worker"),
            webrtc / "bin/avcodec-dinox-hw-62.dll": fake_pe(b"hardware-avcodec"),
            webrtc / "bin/avutil-dinox-hw-60.dll": fake_pe(b"hardware-avutil"),
            tor: fake_pe(b"tor-source"),
            openssl: fake_pe(b"openssl-source"),
            lyrebird: fake_pe(b"lyrebird"),
            mingw / "bin/libfoo.dll": fake_pe(b"package"),
            mingw / "bin/libarchive-13.dll": fake_pe(b"archive-package"),
            mingw / "bin/libomemo-c.dll": fake_pe(b"libomemo"),
        }
        for path, content in fixture_files.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            target = (
                dist / "lib/gio/modules/libgiognutls.dll"
                if path.name == "libgiognutls.dll"
                else
                dist / "bin/dinox-backup-tar.exe"
                if path.name == "dinox-backup-tar.exe"
                else dist / "plugins/omemo.dll"
                if path.name == "omemo.dll"
                else dist / "bin/openssl.exe"
                if path == openssl
                else dist / "bin/tor.exe"
                if path == tor
                else dist / "bin/lyrebird.exe"
                if path.name == "lyrebird.exe"
                else dist / path.name
            )
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(
                content + UTF8_MANIFEST_MARKER
                if path in {openssl, tor}
                else content
            )

        google_notices = dist / "share/licenses/dinox/google-libwebrtc"
        google_notices.mkdir(parents=True)
        for filename in ("LICENSE", "LICENSE.md", "PATENTS"):
            (google_notices / filename).write_text(f"{filename}\n", encoding="utf-8")
        (google_notices / "manifest.json").write_text(
            json.dumps(
                {
                    "webrtc_commit": "b" * 40,
                    "webrtc_milestone": 150,
                }
            ),
            encoding="utf-8",
        )
        (google_notices / "FFMPEG-WINDOWS-HARDWARE.json").write_text(
            json.dumps({"ffmpeg_version": "8.1.2"}), encoding="utf-8")
        for relative in (
            "FFMPEG-LICENSE", "CODEC-SOURCES.md",
            "sources/ffmpeg-mf-dynamic-bitrate.patch",
        ):
            source = google_notices / relative
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text("fixture hardware provider source/license\n", encoding="utf-8")

        package_license = mingw / "share/licenses/libfoo/FTL.TXT"
        package_license.parent.mkdir(parents=True)
        package_license.write_text("FreeType-style license fixture\n", encoding="utf-8")
        package_font = mingw / "share/fonts/fixture/font.ttf"
        package_font.parent.mkdir(parents=True)
        package_font.write_bytes(b"fixture-font")
        dist_font = dist / "share/fonts/fixture/font.ttf"
        dist_font.parent.mkdir(parents=True)
        shutil.copy2(package_font, dist_font)
        write_fake_package(
            msys,
            "mingw-w64-x86_64-libfoo",
            "1.0-1",
            (
                "mingw64/bin/libfoo.dll",
                "mingw64/share/fonts/fixture/font.ttf",
                "mingw64/share/licenses/libfoo/FTL.TXT",
            ),
        )
        archive_license = mingw / "share/licenses/libarchive/COPYING"
        archive_license.parent.mkdir(parents=True)
        archive_license.write_text("libarchive license fixture\n", encoding="utf-8")
        write_fake_package(
            msys,
            "mingw-w64-x86_64-libarchive",
            "3.99.0-1",
            (
                "mingw64/bin/libarchive-13.dll",
                "mingw64/share/licenses/libarchive/COPYING",
            ),
        )
        asset_only_font = mingw / "share/fonts/asset-only/font.otf"
        asset_only_font.parent.mkdir(parents=True)
        asset_only_font.write_bytes(b"asset-only-font")
        dist_asset_only_font = dist / "share/fonts/asset-only/font.otf"
        dist_asset_only_font.parent.mkdir(parents=True)
        shutil.copy2(asset_only_font, dist_asset_only_font)
        asset_only_license = mingw / "share/licenses/asset-only/LICENSE"
        asset_only_license.parent.mkdir(parents=True)
        asset_only_license.write_text("Asset-only MIT fixture\n", encoding="utf-8")
        write_fake_package(
            msys,
            "mingw-w64-x86_64-asset-only",
            "2.0-1",
            (
                "mingw64/share/fonts/asset-only/font.otf",
                "mingw64/share/licenses/asset-only/LICENSE",
            ),
        )
        tor_license = mingw / "share/licenses/tor/LICENSE"
        tor_license.parent.mkdir(parents=True)
        tor_license.write_text("Tor BSD fixture\n", encoding="utf-8")
        write_fake_package(
            msys,
            TOR_PACKAGE_NAME,
            TOR_PACKAGE_VERSION,
            (
                "mingw64/bin/tor.exe",
                "mingw64/share/licenses/tor/LICENSE",
            ),
        )
        openssl_license = mingw / "share/licenses/openssl/LICENSE.txt"
        openssl_license.parent.mkdir(parents=True)
        openssl_license.write_text("OpenSSL Apache fixture\n", encoding="utf-8")
        write_fake_package(
            msys,
            OPENSSL_PACKAGE_NAME,
            "3.99.0-1",
            (
                "mingw64/bin/openssl.exe",
                "mingw64/share/licenses/openssl/LICENSE.txt",
            ),
        )

        for name, expected in CUSTOM_COMPONENTS.items():
            custom_root = (
                vendor
                / "windows-license-material"
                / str(expected["directory"])
            )
            (custom_root / "files").mkdir(parents=True)
            (custom_root / "files/LICENSE").write_text(
                f"{name} license\n", encoding="utf-8"
            )
            extra_metadata: tuple[str, ...] = ()
            if name == "lyrebird":
                go_notice = custom_root / "files/toolchain/go"
                go_notice.mkdir(parents=True)
                (go_notice / "LICENSE").write_text(
                    "Go runtime license\n", encoding="utf-8"
                )
                (go_notice / "PATENTS").write_text(
                    "Go patents notice\n", encoding="utf-8"
                )
                module_notice = (
                    custom_root
                    / "files/vendor/example.test/module/LICENSE"
                )
                module_notice.parent.mkdir(parents=True)
                module_notice.write_text(
                    "Example module license\n", encoding="utf-8"
                )
                with (go_notice / "GO-MODULES.tsv").open(
                    "w", encoding="utf-8", newline=""
                ) as handle:
                    writer = csv.writer(
                        handle, dialect="excel-tab", lineterminator="\n"
                    )
                    writer.writerow(GO_MODULE_HEADER)
                    writer.writerow(
                        (
                            "example.test/module",
                            "v1.0.0",
                            "example.test/module",
                            "v1.0.0",
                            "h1:fixture",
                            "",
                            "vendor/example.test/module/LICENSE",
                        )
                    )
                extra_metadata = (
                    "go_version=go1.99.0",
                    "go_license_expression=BSD-3-Clause",
                    "go_source_url=https://go.dev/dl/go1.99.0.src.tar.gz",
                    "go_source_sha256=" + "c" * 64,
                )
            (custom_root / "METADATA").write_text(
                "\n".join(
                    (
                        f"component={name}",
                        f"version={expected['version']}",
                        f"checksum_algorithm={expected['checksum_algorithm']}",
                        f"checksum={expected['checksum']}",
                        "license_expression=fixture-license",
                        f"source_url=https://example.test/{name}.tar.gz",
                        *extra_metadata,
                        "",
                    )
                ),
                encoding="utf-8",
            )
        (lyrebird.parent / "BUILD-METADATA").write_text(
            "\n".join(
                (
                    "component=lyrebird",
                    f"version={CUSTOM_COMPONENTS['lyrebird']['version']}",
                    f"source_sha256={CUSTOM_COMPONENTS['lyrebird']['checksum']}",
                    "go_version=go1.99.0",
                    f"binary_sha256={sha256_file(lyrebird)}",
                    "",
                )
            ),
            encoding="utf-8",
        )

        args = argparse.Namespace(
            project=project,
            dist=dist,
            build=build,
            vendor_root=vendor,
            mingw_root=mingw,
            msys_root=msys,
            webrtc_root=webrtc,
            tor=tor,
            openssl=openssl,
            lyrebird=lyrebird,
            _allow_non_windows_transform_fixture=True,
        )
        stage(args)
        verify_distribution(dist)
        # A regular MSYS2 GIO module must not silently replace our UTF-8 fix.
        gio_artifact = dist / "lib/gio/modules/libgiognutls.dll"
        gio_original = gio_artifact.read_bytes()
        gio_artifact.write_bytes(fake_pe(b"unpatched-gio"))
        try:
            stage(args)
        except InventoryError:
            pass
        else:
            fail("self-test accepted an unpatched GIO TLS module")
        gio_artifact.write_bytes(gio_original)
        stage(args)
        with (dist / "share/licenses/dinox" / INVENTORY_NAME).open(
            encoding="utf-8", newline=""
        ) as handle:
            records = {
                row["path"]: row for row in csv.DictReader(handle, dialect="excel-tab")
            }
        if records["bin/dinox-backup-tar.exe"]["origin"] != "dinox-source":
            fail("self-test did not classify the built backup helper as DinoX source")
        archive_record = records["libarchive-13.dll"]
        if (
            archive_record["origin"] != "msys2-package"
            or archive_record["component"] != "mingw-w64-x86_64-libarchive"
        ):
            fail("self-test did not classify the archive DLL by its MSYS2 package")
        inventory = (
            dist / "share/licenses/dinox" / INVENTORY_NAME
        ).read_text(encoding="utf-8")
        inventory += (
            dist / "share/licenses/dinox" / STATIC_INVENTORY_NAME
        ).read_text(encoding="utf-8")
        for expected_text in (
            "dinox-source",
            "google-libwebrtc",
            "ffmpeg-hardware-codecs",
            "custom-source",
            "msys2-package",
            "go-module:example.test/module",
        ):
            if expected_text not in inventory:
                fail(f"self-test inventory is missing {expected_text}")

        (dist / "unclassified.dll").write_bytes(fake_pe(b"unknown"))
        try:
            verify_distribution(dist)
        except InventoryError:
            pass
        else:
            fail("self-test accepted an unclassified packaged DLL")
        (dist / "unclassified.dll").unlink()

        hidden_pe = dist / "hidden.bin"
        hidden_pe.write_bytes(fake_pe(b"hidden"))
        try:
            verify_distribution(dist)
        except InventoryError:
            pass
        else:
            fail("self-test accepted an uninventoried PE with a nonstandard suffix")
        hidden_pe.unlink()

        unknown_asset = dist / "share/fonts/unknown/font.ttf"
        unknown_asset.parent.mkdir(parents=True)
        unknown_asset.write_bytes(b"unknown-asset")
        try:
            verify_distribution(dist)
        except InventoryError:
            pass
        else:
            fail("self-test accepted an uninventoried runtime asset")
        unknown_asset.unlink()

        forbidden_archive = dist / "unexpected-source.tar.zst"
        forbidden_archive.write_bytes(b"source archive")
        try:
            verify_distribution(dist)
        except InventoryError:
            pass
        else:
            fail("self-test accepted a source archive in portable dist")
    print("Self-test OK")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Stage or verify the DinoX portable Windows PE license inventory."
    )
    subparsers = result.add_subparsers(dest="command", required=True)
    stage_parser = subparsers.add_parser("stage")
    stage_parser.add_argument("--project", type=Path, required=True)
    stage_parser.add_argument("--dist", type=Path, required=True)
    stage_parser.add_argument("--build", type=Path, required=True)
    stage_parser.add_argument("--vendor-root", type=Path, required=True)
    stage_parser.add_argument("--mingw-root", type=Path, required=True)
    stage_parser.add_argument("--msys-root", type=Path, required=True)
    stage_parser.add_argument("--webrtc-root", type=Path, required=True)
    stage_parser.add_argument("--tor", type=Path, required=True)
    stage_parser.add_argument("--openssl", type=Path, required=True)
    stage_parser.add_argument("--lyrebird", type=Path, required=True)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--dist", type=Path, required=True)
    subparsers.add_parser("self-test")
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "stage":
            stage(args)
        elif args.command == "verify":
            verify_distribution(args.dist)
        else:
            run_self_test()
    except (InventoryError, OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
