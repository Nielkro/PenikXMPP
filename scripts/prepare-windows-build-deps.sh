#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PARENT="$(cd "$PROJECT_ROOT/.." && pwd)"
VENDOR_ROOT="${DINOX_WINDOWS_VENDOR_ROOT:-$PROJECT_PARENT/vendor-deps}"
DOWNLOAD_ROOT="$VENDOR_ROOT/downloads"
LICENSE_MATERIAL_ROOT="$VENDOR_ROOT/windows-license-material"

PANGO_PACKAGE="mingw-w64-x86_64-pango-1.56.4-3-any.pkg.tar.zst"
PANGO_SHA256="1fee019635e04912edf2ae43e066fc83d1bd4b740496504bcfecc66a0088f527"
PANGO_URL="https://repo.msys2.org/mingw/mingw64/$PANGO_PACKAGE"

TOR_PACKAGE="mingw-w64-x86_64-tor-0.4.9.12-1-any.pkg.tar.zst"
TOR_SHA256="5f49afe442e00f0fa5c74f028cc8fa80ae46a1ab8c785f4d90982aae0b93f3e2"
TOR_URL="https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/$TOR_PACKAGE"

LIBOMEMO_VERSION="0.5.1"
LIBOMEMO_ARCHIVE="libomemo-c-$LIBOMEMO_VERSION.tar.gz"
LIBOMEMO_SHA512="ff59565406c51663f2944e9a7c12c5b0e3fa01073039f5161472dd81f59194b1cf2685bc1e0cc930a141bc409b965c5d93313cfc3e0e237250102af3b5e88826"
LIBOMEMO_URL="https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/$LIBOMEMO_ARCHIVE"

LYREBIRD_VERSION="0.8.1"
LYREBIRD_ARCHIVE="lyrebird-$LYREBIRD_VERSION-vendored.tar.gz"
LYREBIRD_SHA256="05d87533c66562baae8a0adac6ae7f7401aa08516ea0dfd192a367d2f8645092"
LYREBIRD_URL="https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/$LYREBIRD_ARCHIVE"
LYREBIRD_ROOT="$VENDOR_ROOT/lyrebird-$LYREBIRD_VERSION"
LYREBIRD_BUILD_METADATA="$LYREBIRD_ROOT/BUILD-METADATA"

WEBRTC_ARCHIVE="libwebrtc-m152-windows-x86_64-runtime-abi40-ipc10-sha256-32ebb90ba8cb.zip"
WEBRTC_SHA256="32ebb90ba8cbe340dc7e398db8f38a8df5d74204a58b78618888afe0e465db44"
WEBRTC_URL="https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/$WEBRTC_ARCHIVE"
WEBRTC_ARCHIVE_ROOT="libwebrtc-m152-windows-x86_64-runtime"
WEBRTC_ROOT="$VENDOR_ROOT/libwebrtc-m152-windows-x86_64"
WEBRTC_ASSET_MARKER_NAME=".dinox-vendor-asset"
WEBRTC_CHECK_SCRIPT="$PROJECT_ROOT/scripts/check-libwebrtc-windows-runtime.sh"
WEBRTC_INSTALL_LOCK="$VENDOR_ROOT/.dinox-libwebrtc-runtime.lock"
WEBRTC_ROLLBACK_ROOT="$WEBRTC_ROOT.dinox-rollback"

usage() {
    cat <<EOF
Usage: $0 [--self-test|-h|--help]

Prepares the pinned public dependencies for a DinoX Windows build:
  - MSYS2 Pango 1.56.4-3 and Tor 0.4.9.12
  - libomemo-c 0.5.1 in /mingw64
  - Lyrebird 0.8.1 in $LYREBIRD_ROOT
  - Google/libwebrtc M152 runtime in $WEBRTC_ROOT
  - private GIO/GnuTLS module with UTF-8 CA filename support
  - verified dependency licenses and source/patch metadata

Override the download/build directory with DINOX_WINDOWS_VENDOR_ROOT.
Run this script from an MSYS2 MINGW64 shell after installing the packages
listed in docs/internal/WINDOWS_BUILD.md.
EOF
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

write_webrtc_asset_marker() {
    local runtime_root="$1"
    local marker="$runtime_root/$WEBRTC_ASSET_MARKER_NAME"
    local partial="$marker.part.$$"

    rm -f -- "$partial"
    {
        printf 'archive=%s\n' "$WEBRTC_ARCHIVE"
        printf 'sha256=%s\n' "$WEBRTC_SHA256"
    } > "$partial"
    chmod 0644 "$partial"
    mv -f -- "$partial" "$marker"
}

webrtc_asset_marker_matches() {
    local runtime_root="$1"
    local marker="$runtime_root/$WEBRTC_ASSET_MARKER_NAME"
    local archive_line
    local sha256_line
    local extra_line

    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    {
        IFS= read -r archive_line || return 1
        IFS= read -r sha256_line || return 1
        if IFS= read -r extra_line; then
            return 1
        fi
    } < "$marker"
    [[ "$archive_line" == "archive=$WEBRTC_ARCHIVE" ]] || return 1
    [[ "$sha256_line" == "sha256=$WEBRTC_SHA256" ]]
}

webrtc_runtime_matches_pinned_asset() {
    local runtime_root="$1"

    webrtc_asset_marker_matches "$runtime_root" || return 1
    "$WEBRTC_CHECK_SCRIPT" "$runtime_root" >/dev/null 2>&1
}

acquire_webrtc_install_lock() {
    local lock_dir="$WEBRTC_INSTALL_LOCK"
    local owner_pid=""

    if mkdir -- "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock_dir/pid" \
            || {
                rm -f -- "$lock_dir/pid"
                rmdir -- "$lock_dir" 2>/dev/null || true
                return 1
            }
        return 0
    fi

    [[ -d "$lock_dir" && ! -L "$lock_dir" ]] \
        || fail "unsafe Google/libwebrtc install lock: $lock_dir"
    if [[ -f "$lock_dir/pid" && ! -L "$lock_dir/pid" ]]; then
        IFS= read -r owner_pid < "$lock_dir/pid" || owner_pid=""
    fi
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
        fail "another Google/libwebrtc runtime installation is active (PID $owner_pid)"
    fi
    fail "stale Google/libwebrtc install lock found; verify no prepare process is active, then remove $lock_dir"
}

release_webrtc_install_lock() {
    local lock_dir="$WEBRTC_INSTALL_LOCK"
    local owner_pid=""

    if [[ -f "$lock_dir/pid" && ! -L "$lock_dir/pid" ]]; then
        IFS= read -r owner_pid < "$lock_dir/pid" || owner_pid=""
    fi
    if [[ "$owner_pid" == "$$" ]]; then
        rm -f -- "$lock_dir/pid"
        rmdir -- "$lock_dir" 2>/dev/null || true
    fi
}

recover_interrupted_webrtc_swap() {
    [[ -e "$WEBRTC_ROLLBACK_ROOT" || -L "$WEBRTC_ROLLBACK_ROOT" ]] || return 0

    if webrtc_runtime_matches_pinned_asset "$WEBRTC_ROOT"; then
        rm -rf -- "$WEBRTC_ROLLBACK_ROOT"
        return 0
    fi

    rm -rf -- "$WEBRTC_ROOT"
    mv -- "$WEBRTC_ROLLBACK_ROOT" "$WEBRTC_ROOT" \
        || fail "could not restore Google/libwebrtc runtime after an interrupted update"
    echo "==> Restored Google/libwebrtc runtime after an interrupted update"
}

install_staged_webrtc_runtime() {
    local staged_root="$1"
    local had_previous=0

    [[ ! -e "$WEBRTC_ROLLBACK_ROOT" && ! -L "$WEBRTC_ROLLBACK_ROOT" ]] \
        || return 1
    if [[ -e "$WEBRTC_ROOT" || -L "$WEBRTC_ROOT" ]]; then
        mv -- "$WEBRTC_ROOT" "$WEBRTC_ROLLBACK_ROOT" || return 1
        had_previous=1
    fi

    if mv -- "$staged_root" "$WEBRTC_ROOT" \
            && webrtc_runtime_matches_pinned_asset "$WEBRTC_ROOT"; then
        rm -rf -- "$WEBRTC_ROLLBACK_ROOT"
        return 0
    fi

    rm -rf -- "$WEBRTC_ROOT"
    if [[ "$had_previous" -eq 1 ]]; then
        mv -- "$WEBRTC_ROLLBACK_ROOT" "$WEBRTC_ROOT" || {
            echo "FAIL: runtime update failed and rollback is still at $WEBRTC_ROLLBACK_ROOT" >&2
            return 1
        }
    fi
    return 1
}

normalize_go_buildinfo() {
    tr -d '\r' \
        | sed -E '1s|^.*: (go[0-9]+(\.[0-9]+)+)$|lyrebird.exe: \1|'
}

download() {
    local url="$1"
    local output="$2"
    local partial="$output.part"

    if [ ! -s "$output" ]; then
        echo "==> Downloading $(basename "$output")"
        rm -f "$partial"
        curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
            "$url" --output "$partial"
        mv "$partial" "$output"
    fi
}

check_sha256() {
    local expected="$1"
    local file="$2"
    printf '%s  %s\n' "$expected" "$file" | sha256sum --check -
}

check_sha512() {
    local expected="$1"
    local file="$2"
    printf '%s  %s\n' "$expected" "$file" | sha512sum --check -
}

download_sha256() {
    local url="$1"
    local output="$2"
    local expected="$3"

    if [ -s "$output" ] && check_sha256 "$expected" "$output" >/dev/null 2>&1; then
        echo "==> Using verified cached $(basename "$output")"
        return
    fi
    if [ -e "$output" ]; then
        echo "==> Replacing incomplete or corrupt $(basename "$output")"
        rm -f "$output"
    fi
    download "$url" "$output"
    check_sha256 "$expected" "$output"
}

download_sha512() {
    local url="$1"
    local output="$2"
    local expected="$3"

    if [ -s "$output" ] && check_sha512 "$expected" "$output" >/dev/null 2>&1; then
        echo "==> Using verified cached $(basename "$output")"
        return
    fi
    if [ -e "$output" ]; then
        echo "==> Replacing incomplete or corrupt $(basename "$output")"
        rm -f "$output"
    fi
    download "$url" "$output"
    check_sha512 "$expected" "$output"
}

stage_license_tree() {
    local component="$1"
    local version="$2"
    local source_root="$3"
    local destination="$4"
    local checksum_algorithm="$5"
    local checksum="$6"
    local source_url="$7"
    local license_expression="$8"
    local staged_root

    staged_root="$(mktemp -d "$VENDOR_ROOT/windows-license-stage.XXXXXX")"
    DINOX_FLATPAK_APP_PREFIX="$staged_root/app" \
        bash "$PROJECT_ROOT/scripts/stage-flatpak-module-licenses.sh" \
            "$component" "$source_root"

    rm -rf "$destination"
    mkdir -p "$destination/files"
    cp -R \
        "$staged_root/app/share/licenses/dinox/third-party/$component/." \
        "$destination/files/"
    {
        printf 'component=%s\n' "$component"
        printf 'version=%s\n' "$version"
        printf 'checksum_algorithm=%s\n' "$checksum_algorithm"
        printf 'checksum=%s\n' "$checksum"
        printf 'source_url=%s\n' "$source_url"
        printf 'license_expression=%s\n' "$license_expression"
    } > "$destination/METADATA"
    find "$destination/files" -type f -size +0c -print -quit | grep -q . \
        || fail "no Windows license material staged for $component"
    rm -rf "$staged_root"
}

prepare_libomemo_license_material() {
    local archive="$DOWNLOAD_ROOT/$LIBOMEMO_ARCHIVE"
    local work
    local source
    local destination="$LICENSE_MATERIAL_ROOT/libomemo-c-$LIBOMEMO_VERSION"

    download_sha512 "$LIBOMEMO_URL" "$archive" "$LIBOMEMO_SHA512"
    work="$(mktemp -d "$VENDOR_ROOT/libomemo-license.XXXXXX")"
    tar -xzf "$archive" -C "$work"
    source="$work/libomemo-c-$LIBOMEMO_VERSION"
    [ -d "$source" ] || fail "unexpected libomemo-c archive layout"
    stage_license_tree \
        "libomemo-c" \
        "$LIBOMEMO_VERSION" \
        "$source" \
        "$destination" \
        "sha512" \
        "$LIBOMEMO_SHA512" \
        "$LIBOMEMO_URL" \
        "GPL-3.0-or-later WITH App-Store-additional-permission"
    rm -rf "$work"
    echo "==> Staged verified libomemo-c license material"
}

prepare_lyrebird_license_material() {
    local archive="$DOWNLOAD_ROOT/$LYREBIRD_ARCHIVE"
    local work
    local source
    local destination="$LICENSE_MATERIAL_ROOT/lyrebird-$LYREBIRD_VERSION"
    local go_archive
    local go_archive_name
    local go_archive_sha256
    local go_downloads_json
    local go_source
    local go_version
    local build_metadata="$LYREBIRD_BUILD_METADATA"

    download_sha256 "$LYREBIRD_URL" "$archive" "$LYREBIRD_SHA256"
    work="$(mktemp -d "$VENDOR_ROOT/lyrebird-license.XXXXXX")"
    tar -xzf "$archive" -C "$work"
    source="$(find "$work" -mindepth 1 -maxdepth 4 -type d \
        -path '*/cmd/lyrebird' -printf '%h\n' -quit)"
    [ -n "$source" ] || fail "unexpected Lyrebird archive layout"
    source="$(dirname "$source")"
    stage_license_tree \
        "lyrebird" \
        "$LYREBIRD_VERSION" \
        "$source" \
        "$destination" \
        "sha256" \
        "$LYREBIRD_SHA256" \
        "$LYREBIRD_URL" \
        "Multiple licenses; see bundled license and notice files"
    [ -s "$build_metadata" ] \
        || fail "validated Lyrebird build metadata is missing: $build_metadata"
    go_version="$(sed -n 's/^go_version=//p' "$build_metadata")"
    [[ "$go_version" =~ ^go[0-9]+(\.[0-9]+)+$ ]] \
        || fail "unexpected embedded Go version: $go_version"
    go_downloads_json="$DOWNLOAD_ROOT/go-downloads.json"
    rm -f "$go_downloads_json.part"
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        'https://go.dev/dl/?mode=json&include=all' \
        --output "$go_downloads_json.part"
    mv "$go_downloads_json.part" "$go_downloads_json"
    read -r go_archive_name go_archive_sha256 < <(
        python3 - "$go_downloads_json" "$go_version" <<'PY'
import json
import pathlib
import re
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
version = sys.argv[2]
matches = [
    item
    for release in data
    if release.get("version") == version
    for item in release.get("files", [])
    if item.get("kind") == "source"
]
if len(matches) != 1:
    raise SystemExit(f"expected one official Go source record for {version}")
item = matches[0]
filename = item.get("filename", "")
checksum = item.get("sha256", "")
if filename != f"{version}.src.tar.gz" or not re.fullmatch(r"[0-9a-f]{64}", checksum):
    raise SystemExit(f"invalid official Go source metadata for {version}")
print(filename, checksum)
PY
    )
    # Native Windows Python writes CRLF to the process substitution. Bash
    # removes LF for `read` but leaves CR on the final checksum field.
    go_archive_name="${go_archive_name//$'\r'/}"
    go_archive_sha256="${go_archive_sha256//$'\r'/}"
    [[ "$go_archive_name" == "$go_version.src.tar.gz" \
            && "$go_archive_sha256" =~ ^[0-9a-f]{64}$ ]] \
        || fail "invalid normalized Go source metadata for $go_version"
    go_archive="$DOWNLOAD_ROOT/$go_archive_name"
    download_sha256 \
        "https://go.dev/dl/$go_archive_name" \
        "$go_archive" \
        "$go_archive_sha256"
    go_source="$work/go-source"
    mkdir -p "$go_source"
    tar -xzf "$go_archive" -C "$go_source"
    [ -s "$go_source/go/LICENSE" ] \
        || fail "Go runtime LICENSE is missing from official source archive"
    [ -s "$go_source/go/PATENTS" ] \
        || fail "Go runtime PATENTS is missing from official source archive"
    mkdir -p "$destination/files/toolchain/go"
    cp "$go_source/go/LICENSE" "$go_source/go/PATENTS" \
        "$destination/files/toolchain/go/"
    go version -m "$LYREBIRD_ROOT/lyrebird.exe" \
        | normalize_go_buildinfo \
        > "$destination/files/toolchain/go/BUILDINFO.txt"
    head -n 1 "$destination/files/toolchain/go/BUILDINFO.txt" \
        | grep -Fx "lyrebird.exe: $go_version" >/dev/null \
        || fail "Lyrebird Go build info contains an unexpected executable path"
    python3 - \
        "$destination/files/toolchain/go/BUILDINFO.txt" \
        "$source/vendor/modules.txt" \
        "$source/vendor" \
        "$destination/files" \
        "$destination/files/toolchain/go/GO-MODULES.tsv" <<'PY'
import csv
import hashlib
import pathlib
import re
import sys

buildinfo = pathlib.Path(sys.argv[1])
modules_file = pathlib.Path(sys.argv[2])
vendor_root = pathlib.Path(sys.argv[3])
staged_root = pathlib.Path(sys.argv[4])
output = pathlib.Path(sys.argv[5])


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def digest(path: pathlib.Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def license_name(path: pathlib.Path) -> bool:
    name = path.name.upper()
    if name == "UNLICENSE":
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
            "NOTICE",
            "PATENTS",
        )
    )


lines = buildinfo.read_text(encoding="utf-8").splitlines()
if not lines or not re.search(r": go[0-9]+(?:\.[0-9]+)+$", lines[0]):
    fail("invalid Lyrebird Go build-info header")
main_module = ""
dependencies: dict[str, dict[str, str]] = {}
previous_dependency: dict[str, str] | None = None
for raw in lines[1:]:
    fields = raw.lstrip("\t").split("\t")
    if not fields:
        continue
    kind = fields[0]
    if kind == "path":
        if len(fields) != 2 or fields[1] != (
            "gitlab.torproject.org/tpo/anti-censorship/"
            "pluggable-transports/lyrebird/cmd/lyrebird"
        ):
            fail("unexpected Lyrebird main package path")
    elif kind == "mod":
        if len(fields) < 3:
            fail("invalid Lyrebird main-module build-info")
        main_module = fields[1]
        if main_module != (
            "gitlab.torproject.org/tpo/anti-censorship/"
            "pluggable-transports/lyrebird"
        ) or fields[2] != "(devel)":
            fail("unexpected Lyrebird main module")
    elif kind == "dep":
        if len(fields) not in {3, 4} or fields[1] in dependencies:
            fail("invalid or duplicate Lyrebird dependency build-info")
        previous_dependency = {
            "requested": fields[1],
            "requested_version": fields[2],
            "module_sum": fields[3] if len(fields) == 4 else "",
            "resolved": fields[1],
            "resolved_version": fields[2],
            "replacement_sum": "",
        }
        dependencies[fields[1]] = previous_dependency
    elif kind == "=>":
        if previous_dependency is None or len(fields) not in {3, 4}:
            fail("orphaned or invalid Lyrebird module replacement")
        previous_dependency["resolved"] = fields[1]
        previous_dependency["resolved_version"] = fields[2]
        previous_dependency["replacement_sum"] = fields[3] if len(fields) == 4 else ""
        previous_dependency = None
    else:
        previous_dependency = None
if not main_module or not dependencies:
    fail("Lyrebird build-info has no main module or dependencies")

vendor_modules: dict[str, tuple[str, str, str]] = {}
for raw in modules_file.read_text(encoding="utf-8").splitlines():
    if not raw.startswith("# ") or raw.startswith("## "):
        continue
    body = raw[2:]
    left, separator, right = body.partition(" => ")
    left_fields = left.split()
    if len(left_fields) != 2:
        continue
    requested, requested_version = left_fields
    resolved = requested
    resolved_version = requested_version
    if separator:
        right_fields = right.split()
        if len(right_fields) != 2:
            fail(f"invalid vendored replacement header: {raw}")
        resolved, resolved_version = right_fields
    if requested in vendor_modules:
        fail(f"duplicate vendored module header: {requested}")
    vendor_modules[requested] = (requested_version, resolved, resolved_version)

rows: list[tuple[str, ...]] = []
for requested, dependency in sorted(dependencies.items()):
    vendor = vendor_modules.get(requested)
    if vendor is None:
        fail(f"binary dependency is absent from vendor/modules.txt: {requested}")
    expected = (
        dependency["requested_version"],
        dependency["resolved"],
        dependency["resolved_version"],
    )
    if vendor != expected:
        fail(
            f"binary/vendor module mismatch for {requested}: "
            f"binary={expected!r}, vendor={vendor!r}"
        )
    module_root = vendor_root / pathlib.Path(*requested.split("/"))
    if not module_root.is_dir():
        fail(f"vendored module directory is missing: {requested}")
    source_licenses = sorted(
        path
        for path in module_root.iterdir()
        if path.is_file() and path.stat().st_size > 0 and license_name(path)
    )
    if not source_licenses:
        fail(f"vendored module has no direct license/notice file: {requested}")
    staged_paths: list[str] = []
    for source_license in source_licenses:
        relative = pathlib.Path("vendor") / pathlib.Path(
            *requested.split("/")
        ) / source_license.name
        staged = staged_root / relative
        if (
            not staged.is_file()
            or staged.stat().st_size != source_license.stat().st_size
            or digest(staged) != digest(source_license)
        ):
            fail(f"staged module license is missing or changed: {relative}")
        staged_paths.append(relative.as_posix())
    rows.append(
        (
            requested,
            dependency["requested_version"],
            dependency["resolved"],
            dependency["resolved_version"],
            dependency["module_sum"],
            dependency["replacement_sum"],
            ";".join(staged_paths),
        )
    )

with output.open("w", encoding="utf-8", newline="") as handle:
    writer = csv.writer(handle, dialect="excel-tab", lineterminator="\n")
    writer.writerow(
        (
            "requested_module",
            "requested_version",
            "resolved_module",
            "resolved_version",
            "module_sum",
            "replacement_sum",
            "license_paths",
        )
    )
    writer.writerows(rows)
PY
    {
        printf 'go_version=%s\n' "$go_version"
        printf 'go_license_expression=BSD-3-Clause\n'
        printf 'go_source_url=https://go.dev/dl/%s.src.tar.gz\n' "$go_version"
        printf 'go_source_sha256=%s\n' "$go_archive_sha256"
    } >> "$destination/METADATA"
    rm -rf "$work"
    echo "==> Staged verified Lyrebird license material"
}

verify_msys2_package() {
    local package="$1"
    local expected_sha256="$2"
    local url="$3"
    local package_path="$DOWNLOAD_ROOT/$package"
    local signature_path="$package_path.sig"

    download_sha256 "$url" "$package_path" "$expected_sha256"
    download "$url.sig" "$signature_path"
    if ! gpgv --keyring /etc/pacman.d/gnupg/pubring.gpg \
            "$signature_path" "$package_path"; then
        echo "==> Replacing invalid cached signature for $package"
        rm -f "$signature_path"
        download "$url.sig" "$signature_path"
        gpgv --keyring /etc/pacman.d/gnupg/pubring.gpg \
            "$signature_path" "$package_path"
    fi
}

install_pinned_msys2_packages() {
    echo "==> Verifying pinned MSYS2 packages"
    verify_msys2_package "$PANGO_PACKAGE" "$PANGO_SHA256" "$PANGO_URL"
    verify_msys2_package "$TOR_PACKAGE" "$TOR_SHA256" "$TOR_URL"

    echo "==> Installing pinned Pango and Tor packages"
    pacman -U --noconfirm \
        "$DOWNLOAD_ROOT/$PANGO_PACKAGE" \
        "$DOWNLOAD_ROOT/$TOR_PACKAGE"

    [ "$(pacman -Q mingw-w64-x86_64-pango | awk '{print $2}')" = "1.56.4-3" ] \
        || fail "the validated Pango package is not installed"
    [ "$(pacman -Q mingw-w64-x86_64-tor | awk '{print $2}')" = "0.4.9.12-1" ] \
        || fail "the validated Tor package is not installed"
}

LIBOMEMO_PKGCONFIG_ERROR=""

validate_libomemo_pkgconfig_metadata() {
    local reported_include_root="$1"
    local reported_pc_dir="$2"
    local expected_include_root="$3"
    local expected_pc_dir="$4"
    local include_root
    local pc_dir
    local canonical_expected_include_root
    local canonical_expected_pc_dir
    local pc_file

    LIBOMEMO_PKGCONFIG_ERROR=""
    if ! include_root="$(cd "$reported_include_root" 2>/dev/null && pwd -P)"; then
        LIBOMEMO_PKGCONFIG_ERROR="includedir does not exist: $reported_include_root"
        return 1
    fi
    if ! pc_dir="$(cd "$reported_pc_dir" 2>/dev/null && pwd -P)"; then
        LIBOMEMO_PKGCONFIG_ERROR="pcfiledir does not exist: $reported_pc_dir"
        return 1
    fi
    canonical_expected_include_root="$(cd "$expected_include_root" && pwd -P)"
    canonical_expected_pc_dir="$(cd "$expected_pc_dir" && pwd -P)"
    if [ "$include_root" != "$canonical_expected_include_root" ]; then
        LIBOMEMO_PKGCONFIG_ERROR="includedir is $include_root, expected $canonical_expected_include_root"
        return 1
    fi
    if [ "$pc_dir" != "$canonical_expected_pc_dir" ]; then
        LIBOMEMO_PKGCONFIG_ERROR="pcfiledir is $pc_dir, expected $canonical_expected_pc_dir"
        return 1
    fi

    pc_file="$pc_dir/libomemo-c.pc"
    if ! grep -Fx 'Cflags: -I${includedir}' "$pc_file" >/dev/null 2>&1; then
        LIBOMEMO_PKGCONFIG_ERROR="$pc_file must contain exactly: Cflags: -I\${includedir}"
        return 1
    fi
}

validate_libomemo_pkgconfig() {
    local include_root
    local pc_dir

    if ! include_root="$(pkg-config --variable=includedir libomemo-c 2>/dev/null)" \
            || [ -z "$include_root" ]; then
        LIBOMEMO_PKGCONFIG_ERROR="pkg-config did not report includedir"
        return 1
    fi
    if ! pc_dir="$(pkg-config --variable=pcfiledir libomemo-c 2>/dev/null)" \
            || [ -z "$pc_dir" ]; then
        LIBOMEMO_PKGCONFIG_ERROR="pkg-config did not report pcfiledir"
        return 1
    fi
    validate_libomemo_pkgconfig_metadata \
        "$include_root" \
        "$pc_dir" \
        "/mingw64/include" \
        "/mingw64/lib/pkgconfig"
}

install_libomemo() {
    local archive="$DOWNLOAD_ROOT/$LIBOMEMO_ARCHIVE"
    local work
    local source

    if pkg-config --exact-version="$LIBOMEMO_VERSION" libomemo-c 2>/dev/null \
            && [ -s /mingw64/bin/libomemo-c.dll ] \
            && [ -s /mingw64/lib/libomemo-c.dll.a ] \
            && [ -s /mingw64/include/omemo/curve.h ] \
            && validate_libomemo_pkgconfig; then
        echo "==> libomemo-c $LIBOMEMO_VERSION already validated"
        return
    fi

    download_sha512 "$LIBOMEMO_URL" "$archive" "$LIBOMEMO_SHA512"
    work="$(mktemp -d "$VENDOR_ROOT/libomemo-build.XXXXXX")"
    trap 'rm -rf "$work"' RETURN
    tar -xzf "$archive" -C "$work"
    source="$work/libomemo-c-$LIBOMEMO_VERSION"
    [ -d "$source" ] || fail "unexpected libomemo-c archive layout"

    grep -Fx 'Cflags: -I${includedir}/omemo' "$source/src/libomemo-c.pc.in" >/dev/null \
        || fail "unexpected upstream libomemo-c pkg-config metadata"
    sed -i 's|^Cflags: -I${includedir}/omemo$|Cflags: -I${includedir}|' \
        "$source/src/libomemo-c.pc.in"

    echo "==> Building libomemo-c $LIBOMEMO_VERSION"
    cmake -S "$source" -B "$work/build" -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/mingw64 \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_TESTING=OFF \
        -DLIB_INSTALL_DIR=/mingw64/lib \
        -DINCLUDE_INSTALL_DIR=/mingw64/include \
        -DINSTALL_PKGCONFIG_DIR=/mingw64/lib/pkgconfig \
        -DPBC_LIB=/mingw64/lib/libprotobuf-c.dll.a \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    cmake --build "$work/build"
    cmake --install "$work/build"

    pkg-config --exact-version="$LIBOMEMO_VERSION" libomemo-c \
        || fail "libomemo-c pkg-config validation failed"
    [ -s /mingw64/bin/libomemo-c.dll ] \
        || fail "libomemo-c runtime DLL was not installed"
    [ -s /mingw64/lib/libomemo-c.dll.a ] \
        || fail "libomemo-c import library was not installed"
    [ -s /mingw64/include/omemo/curve.h ] \
        || fail "libomemo-c headers were not installed"
    validate_libomemo_pkgconfig \
        || fail "libomemo-c pkg-config metadata is invalid: $LIBOMEMO_PKGCONFIG_ERROR"

    rm -rf "$work"
    trap - RETURN
}

build_lyrebird() {
    local archive="$DOWNLOAD_ROOT/$LYREBIRD_ARCHIVE"
    local work
    local source

    local binary_sha256
    local embedded_go_version
    local metadata_binary_sha256
    local metadata_go_version
    local metadata_source_sha256

    if [ -x "$LYREBIRD_ROOT/lyrebird.exe" ] \
            && [ -s "$LYREBIRD_BUILD_METADATA" ] \
            && "$LYREBIRD_ROOT/lyrebird.exe" --version 2>&1 \
                | head -n 1 | grep -Fx "lyrebird $LYREBIRD_VERSION" >/dev/null; then
        embedded_go_version="$(
            go version -m "$LYREBIRD_ROOT/lyrebird.exe" \
                | sed -nE '1s/.*: (go[0-9]+(\.[0-9]+)+)$/\1/p'
        )"
        binary_sha256="$(sha256sum "$LYREBIRD_ROOT/lyrebird.exe" | awk '{print $1}')"
        metadata_binary_sha256="$(
            sed -n 's/^binary_sha256=//p' "$LYREBIRD_BUILD_METADATA"
        )"
        metadata_go_version="$(
            sed -n 's/^go_version=//p' "$LYREBIRD_BUILD_METADATA"
        )"
        metadata_source_sha256="$(
            sed -n 's/^source_sha256=//p' "$LYREBIRD_BUILD_METADATA"
        )"
        if [ "$binary_sha256" = "$metadata_binary_sha256" ] \
                && [ "$embedded_go_version" = "$metadata_go_version" ] \
                && [ "$metadata_source_sha256" = "$LYREBIRD_SHA256" ]; then
            echo "==> Lyrebird $LYREBIRD_VERSION already provenance-validated"
            return
        fi
        echo "==> Rebuilding Lyrebird with incomplete or stale provenance metadata"
    fi

    download_sha256 "$LYREBIRD_URL" "$archive" "$LYREBIRD_SHA256"
    work="$(mktemp -d "$VENDOR_ROOT/lyrebird-build.XXXXXX")"
    trap 'rm -rf "$work"' RETURN
    tar -xzf "$archive" -C "$work"
    source="$(find "$work" -mindepth 1 -maxdepth 4 -type d \
        -path '*/cmd/lyrebird' -printf '%h\n' -quit)"
    [ -n "$source" ] || fail "unexpected Lyrebird archive layout"
    source="$(dirname "$source")"

    echo "==> Building Lyrebird $LYREBIRD_VERSION"
    mkdir -p "$LYREBIRD_ROOT"
    (
        cd "$source"
        CGO_ENABLED=0 GOFLAGS=-mod=vendor \
            go build -trimpath \
                -ldflags "-s -w -X main.lyrebirdVersion=$LYREBIRD_VERSION" \
                -o "$LYREBIRD_ROOT/lyrebird.exe" ./cmd/lyrebird
    )
    "$LYREBIRD_ROOT/lyrebird.exe" --version 2>&1 \
        | head -n 1 | grep -Fx "lyrebird $LYREBIRD_VERSION" >/dev/null \
        || fail "built Lyrebird has the wrong version"
    embedded_go_version="$(
        go version -m "$LYREBIRD_ROOT/lyrebird.exe" \
            | sed -nE '1s/.*: (go[0-9]+(\.[0-9]+)+)$/\1/p'
    )"
    [[ "$embedded_go_version" =~ ^go[0-9]+(\.[0-9]+)+$ ]] \
        || fail "could not read the Go version embedded in Lyrebird"
    binary_sha256="$(sha256sum "$LYREBIRD_ROOT/lyrebird.exe" | awk '{print $1}')"
    {
        printf 'component=lyrebird\n'
        printf 'version=%s\n' "$LYREBIRD_VERSION"
        printf 'source_url=%s\n' "$LYREBIRD_URL"
        printf 'source_sha256=%s\n' "$LYREBIRD_SHA256"
        printf 'go_version=%s\n' "$embedded_go_version"
        printf 'binary_sha256=%s\n' "$binary_sha256"
    } > "$LYREBIRD_BUILD_METADATA"

    rm -rf "$work"
    trap - RETURN
}

prepare_webrtc_runtime() (
    local archive="$DOWNLOAD_ROOT/$WEBRTC_ARCHIVE"
    local sidecar="$archive.sha256"
    local work=""
    local staged_root

    acquire_webrtc_install_lock \
        || fail "could not create Google/libwebrtc install lock"
    trap 'status=$?; set +e; if [[ -n "$work" ]]; then rm -rf -- "$work"; fi; release_webrtc_install_lock; exit "$status"' EXIT
    recover_interrupted_webrtc_swap

    if webrtc_runtime_matches_pinned_asset "$WEBRTC_ROOT"; then
        echo "==> Google/libwebrtc M152 runtime already validated"
        return 0
    fi
    if [[ -e "$WEBRTC_ROOT" || -L "$WEBRTC_ROOT" ]]; then
        echo "==> Replacing an incomplete or stale Google/libwebrtc runtime"
    fi

    download_sha256 "$WEBRTC_URL" "$archive" "$WEBRTC_SHA256"
    download "$WEBRTC_URL.sha256" "$sidecar"
    if ! (
        cd "$DOWNLOAD_ROOT"
        sha256sum --check "$(basename "$sidecar")"
    ); then
        echo "==> Replacing invalid cached Google/libwebrtc checksum sidecar"
        rm -f "$sidecar"
        download "$WEBRTC_URL.sha256" "$sidecar"
        (
            cd "$DOWNLOAD_ROOT"
            sha256sum --check "$(basename "$sidecar")"
        )
    fi

    work="$(mktemp -d "$VENDOR_ROOT/libwebrtc-unpack.XXXXXX")"
    unzip -q "$archive" -d "$work"
    staged_root="$work/$WEBRTC_ARCHIVE_ROOT"
    [[ -d "$staged_root" && ! -L "$staged_root" ]] \
        || fail "unexpected Google/libwebrtc runtime archive layout"
    "$WEBRTC_CHECK_SCRIPT" "$staged_root"
    write_webrtc_asset_marker "$staged_root"
    webrtc_runtime_matches_pinned_asset "$staged_root" \
        || fail "staged Google/libwebrtc runtime does not match the repository pin"
    install_staged_webrtc_runtime "$staged_root" \
        || fail "could not install Google/libwebrtc runtime; previous runtime restored"
)

run_self_test() {
    local normalized_buildinfo
    local tmpdir
    local original_check_script
    local original_install_lock

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    [ "$PANGO_SHA256" = "1fee019635e04912edf2ae43e066fc83d1bd4b740496504bcfecc66a0088f527" ] \
        || fail "Pango hash changed unexpectedly"
    [ "$TOR_SHA256" = "5f49afe442e00f0fa5c74f028cc8fa80ae46a1ab8c785f4d90982aae0b93f3e2" ] \
        || fail "Tor hash changed unexpectedly"
    [ "$WEBRTC_SHA256" = "32ebb90ba8cbe340dc7e398db8f38a8df5d74204a58b78618888afe0e465db44" ] \
        || fail "Google/libwebrtc hash changed unexpectedly"
    [ "$WEBRTC_ARCHIVE_ROOT" = "libwebrtc-m152-windows-x86_64-runtime" ] \
        || fail "Google/libwebrtc archive root changed unexpectedly"
    mkdir -p "$tmpdir/webrtc-runtime"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmpdir/check-runtime"
    chmod 0755 "$tmpdir/check-runtime"
    original_check_script="$WEBRTC_CHECK_SCRIPT"
    original_install_lock="$WEBRTC_INSTALL_LOCK"
    WEBRTC_CHECK_SCRIPT="$tmpdir/check-runtime"
    WEBRTC_INSTALL_LOCK="$tmpdir/webrtc-install.lock"
    acquire_webrtc_install_lock \
        || fail "Google/libwebrtc install-lock self-test could not acquire the lock"
    if (acquire_webrtc_install_lock) >/dev/null 2>&1; then
        fail "Google/libwebrtc install-lock self-test allowed a concurrent writer"
    fi
    release_webrtc_install_lock
    [[ ! -e "$WEBRTC_INSTALL_LOCK" && ! -L "$WEBRTC_INSTALL_LOCK" ]] \
        || fail "Google/libwebrtc install-lock self-test did not release the lock"
    if webrtc_runtime_matches_pinned_asset "$tmpdir/webrtc-runtime"; then
        fail "Google/libwebrtc cache self-test accepted a markerless ABI-compatible runtime"
    fi
    write_webrtc_asset_marker "$tmpdir/webrtc-runtime"
    webrtc_runtime_matches_pinned_asset "$tmpdir/webrtc-runtime" \
        || fail "Google/libwebrtc cache self-test rejected the current pinned runtime"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$tmpdir/check-runtime"
    if webrtc_runtime_matches_pinned_asset "$tmpdir/webrtc-runtime"; then
        fail "Google/libwebrtc cache self-test ignored a failing runtime checker"
    fi
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmpdir/check-runtime"
    printf 'archive=%s\n' "$WEBRTC_ARCHIVE" \
        > "$tmpdir/webrtc-runtime/$WEBRTC_ASSET_MARKER_NAME"
    if webrtc_asset_marker_matches "$tmpdir/webrtc-runtime"; then
        fail "Google/libwebrtc marker self-test accepted truncated metadata"
    fi
    printf 'archive=%s\nsha256=%064d\n' "$WEBRTC_ARCHIVE" 0 \
        > "$tmpdir/webrtc-runtime/$WEBRTC_ASSET_MARKER_NAME"
    if webrtc_runtime_matches_pinned_asset "$tmpdir/webrtc-runtime"; then
        fail "Google/libwebrtc cache self-test accepted a stale ABI-compatible runtime"
    fi
    {
        printf 'archive=%s\n' "$WEBRTC_ARCHIVE"
        printf 'sha256=%s\n' "$WEBRTC_SHA256"
        printf 'unexpected=field\n'
    } > "$tmpdir/webrtc-runtime/$WEBRTC_ASSET_MARKER_NAME"
    if webrtc_asset_marker_matches "$tmpdir/webrtc-runtime"; then
        fail "Google/libwebrtc marker self-test accepted extra metadata"
    fi
    WEBRTC_CHECK_SCRIPT="$original_check_script"
    WEBRTC_INSTALL_LOCK="$original_install_lock"
    normalized_buildinfo="$(
        printf '%s\r\n%s\r\n' \
            'C:/msys64/home/private-user/vendor/lyrebird.exe: go1.26.3' \
            $'\tpath\texample.test/lyrebird' \
            | normalize_go_buildinfo
    )"
    [ "$(head -n 1 <<<"$normalized_buildinfo")" = "lyrebird.exe: go1.26.3" ] \
        || fail "Go build-info path normalization failed"
    if grep -F 'private-user' <<<"$normalized_buildinfo" >/dev/null; then
        fail "Go build-info path normalization retained the build user"
    fi

    mkdir -p "$tmpdir/include/omemo" "$tmpdir/lib/pkgconfig" "$tmpdir/other-pkgconfig"
    printf '%s\n' 'Cflags: -I${includedir}' > "$tmpdir/lib/pkgconfig/libomemo-c.pc"
    printf '%s\n' 'Cflags: -I${includedir}' > "$tmpdir/other-pkgconfig/libomemo-c.pc"
    validate_libomemo_pkgconfig_metadata \
        "$tmpdir/include" \
        "$tmpdir/lib/pkgconfig" \
        "$tmpdir/include" \
        "$tmpdir/lib/pkgconfig"
    if validate_libomemo_pkgconfig_metadata \
            "$tmpdir/include/omemo" \
            "$tmpdir/lib/pkgconfig" \
            "$tmpdir/include" \
            "$tmpdir/lib/pkgconfig"; then
        fail "libomemo-c metadata self-test accepted include/omemo as the root"
    fi
    if validate_libomemo_pkgconfig_metadata \
            "$tmpdir/include" \
            "$tmpdir/other-pkgconfig" \
            "$tmpdir/include" \
            "$tmpdir/lib/pkgconfig"; then
        fail "libomemo-c metadata self-test accepted an unrelated pcfiledir"
    fi
    printf '%s\n' 'Cflags: -I${includedir}/omemo' \
        > "$tmpdir/lib/pkgconfig/libomemo-c.pc"
    if validate_libomemo_pkgconfig_metadata \
            "$tmpdir/include" \
            "$tmpdir/lib/pkgconfig" \
            "$tmpdir/include" \
            "$tmpdir/lib/pkgconfig"; then
        fail "libomemo-c metadata self-test accepted the upstream include/omemo Cflags"
    fi

    "$0" --help >/dev/null
    rm -rf "$tmpdir"
    trap - RETURN
    echo "Self-test OK"
}

case "${1:-}" in
    -h|--help)
        [ "$#" -eq 1 ] || { usage >&2; exit 2; }
        usage
        exit 0
        ;;
    --self-test)
        [ "$#" -eq 1 ] || { usage >&2; exit 2; }
        run_self_test
        exit 0
        ;;
    "")
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }

case "$(uname -s)" in
    MINGW*|MSYS*) ;;
    *) fail "run this script inside an MSYS2 MINGW64 shell" ;;
esac

export PATH="/mingw64/bin:/usr/bin:$PATH"
if [ -z "${GOROOT:-}" ] && [ -d /mingw64/lib/go ]; then
    export GOROOT=/mingw64/lib/go
fi

for command_name in curl gpgv pacman sha256sum sha512sum tar unzip cmake ninja \
        pkg-config go gcc find sed grep awk python3; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command not found: $command_name"
done
case "$(gcc -dumpmachine)" in
    x86_64-w64-mingw32) ;;
    *) fail "the active compiler is not the MSYS2 MINGW64 x86_64 toolchain: $(gcc -dumpmachine)" ;;
esac
[ -s /mingw64/lib/libprotobuf-c.dll.a ] \
    || fail "install mingw-w64-x86_64-protobuf-c before running this helper"
pkg-config --exists libarchive \
    || fail "install mingw-w64-x86_64-libarchive before running this helper"
pkg-config --atleast-version=1.19 libunbound \
    || fail "install mingw-w64-x86_64-unbound before running this helper"
python3 -c 'import dns.dnssec, cryptography, h2.connection' \
    || fail "install the documented MSYS2 Python dnspython, cryptography and h2 test packages"

mkdir -p "$VENDOR_ROOT" "$DOWNLOAD_ROOT" "$LICENSE_MATERIAL_ROOT"
install_pinned_msys2_packages
prepare_libomemo_license_material
install_libomemo
build_lyrebird
prepare_lyrebird_license_material
prepare_webrtc_runtime
bash "$PROJECT_ROOT/scripts/prepare-windows-tls.sh"

export DINOX_GOOGLE_WEBRTC_RUNTIME_ROOT="$WEBRTC_ROOT"
export DINOX_LYREBIRD_PATH="$LYREBIRD_ROOT/lyrebird.exe"

echo
echo "WINDOWS_BUILD_DEPS_READY=1"
echo "DINOX_GOOGLE_WEBRTC_RUNTIME_ROOT=$DINOX_GOOGLE_WEBRTC_RUNTIME_ROOT"
echo "DINOX_LYREBIRD_PATH=$DINOX_LYREBIRD_PATH"
echo "Next: bash \"$PROJECT_ROOT/scripts/build-windows-dist.sh\""
