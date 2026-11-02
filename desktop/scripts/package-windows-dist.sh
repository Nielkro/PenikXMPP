#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAX_ZIP_BYTES=$((512 * 1024 * 1024))

usage() {
    cat <<'EOF'
Usage:
  package-windows-dist.sh [DIST_DIR [OUTPUT_DIR]]
  package-windows-dist.sh --self-test

OUTPUT_DIR must be outside DIST_DIR and defaults to the checkout root.
Validates a complete portable Windows dist, creates the canonical
DinoX-VERSION-windows-x86_64.zip and writes its .sha256 sidecar.
EOF
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cleanup_failed_archive() {
    local status=$?

    if [ "$status" -ne 0 ]; then
        if [ -n "${archive:-}" ]; then
            rm -f -- "$archive"
        fi
        if [ -n "${checksum:-}" ]; then
            rm -f -- "$checksum"
        fi
    fi
    exit "$status"
}

require_clean_checkout() {
    local checkout_root="$1"
    local checkout_status

    checkout_status="$(
        git -C "$checkout_root" status --porcelain --untracked-files=normal
    )"
    [ -z "$checkout_status" ] \
        || fail "release ZIP checkout has tracked or untracked source changes"
}

require_output_outside_dist() {
    python3 - "$1" "$2" <<'PYOUTPUT'
import pathlib
import sys

dist = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2]).resolve()
if output == dist or dist in output.parents:
    raise SystemExit("FAIL: Windows ZIP output directory must be outside the portable dist tree")
PYOUTPUT
}

create_archive() {
    local dist_root="$1"
    local archive="$2"
    local top_level="$3"
    local source_epoch="$4"

    python3 - "$dist_root" "$archive" "$top_level" "$source_epoch" <<'PY'
import datetime
import pathlib
import shutil
import stat
import sys
import zipfile

dist = pathlib.Path(sys.argv[1]).resolve()
archive = pathlib.Path(sys.argv[2]).resolve()
top = sys.argv[3]
epoch = int(sys.argv[4])
stamp = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
if stamp.year < 1980:
    stamp = datetime.datetime(1980, 1, 1, tzinfo=datetime.timezone.utc)
date_time = (stamp.year, stamp.month, stamp.day, stamp.hour, stamp.minute, stamp.second)

files = sorted(path for path in dist.rglob("*") if path.is_file())
if not files:
    raise SystemExit("FAIL: Windows dist contains no files")
for path in dist.rglob("*"):
    if path.is_symlink():
        raise SystemExit(f"FAIL: symlink is not allowed in Windows dist: {path}")

archive.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(
    archive,
    "w",
    compression=zipfile.ZIP_DEFLATED,
    compresslevel=9,
    strict_timestamps=True,
) as output:
    for source in files:
        relative = source.relative_to(dist).as_posix()
        info = zipfile.ZipInfo(f"{top}/{relative}", date_time=date_time)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.create_system = 3
        info.external_attr = (stat.S_IFREG | 0o644) << 16
        with source.open("rb") as input_file, output.open(info, "w") as output_file:
            shutil.copyfileobj(input_file, output_file, length=1024 * 1024)
PY
}

verify_archive() {
    local dist_root="$1"
    local archive="$2"
    local top_level="$3"

    python3 - "$dist_root" "$archive" "$top_level" <<'PY'
import hashlib
import pathlib
import sys
import zipfile

dist = pathlib.Path(sys.argv[1]).resolve()
archive = pathlib.Path(sys.argv[2]).resolve()
top = sys.argv[3]
expected = {
    f"{top}/{path.relative_to(dist).as_posix()}": path
    for path in dist.rglob("*")
    if path.is_file()
}

with zipfile.ZipFile(archive) as packed:
    infos = packed.infolist()
    names = [info.filename for info in infos]
    if len(names) != len(set(names)):
        raise SystemExit("FAIL: duplicate path in Windows ZIP")
    if set(names) != set(expected):
        missing = sorted(set(expected) - set(names))
        extra = sorted(set(names) - set(expected))
        raise SystemExit(
            "FAIL: Windows ZIP file-set mismatch "
            f"(missing={missing!r}, extra={extra!r})"
        )
    bad = packed.testzip()
    if bad is not None:
        raise SystemExit(f"FAIL: corrupt Windows ZIP member: {bad}")
    license_size = 0
    for info in infos:
        if info.flag_bits & 0x1:
            raise SystemExit(f"FAIL: encrypted ZIP member is not allowed: {info.filename}")
        relative = info.filename[len(top) + 1 :]
        if relative.startswith("share/licenses/dinox/"):
            license_size += info.file_size
        digest = hashlib.sha256()
        with packed.open(info) as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        expected_digest = hashlib.sha256()
        with expected[info.filename].open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                expected_digest.update(block)
        if digest.digest() != expected_digest.digest():
            raise SystemExit(f"FAIL: ZIP content mismatch: {info.filename}")
    if license_size > 16 * 1024 * 1024:
        raise SystemExit(
            f"FAIL: Windows ZIP license tree is too large: {license_size} bytes"
        )
PY
}

run_self_test() (
    local temporary
    local dist_root
    local archive
    local checksum
    local stale_archive
    local stale_checksum
    local checkout_root
    local top_level="DinoX-1.2.3-windows-x86_64"

    temporary="$(mktemp -d)"
    trap 'rm -rf "$temporary"' EXIT
    dist_root="$temporary/dist"
    archive="$temporary/test.zip"
    mkdir -p "$dist_root/share/licenses/dinox"
    printf '%s\n' "application" > "$dist_root/dinox.exe"
    printf '%s\n' "notices" > "$dist_root/share/licenses/dinox/NOTICE"

    require_output_outside_dist "$dist_root" "$temporary"
    require_output_outside_dist "$dist_root" "$temporary/distribution-output"
    if require_output_outside_dist "$dist_root" "$dist_root" >/dev/null 2>&1; then
        fail "self-test accepted ZIP output in the portable dist root"
    fi
    if require_output_outside_dist "$dist_root" "$dist_root/releases" >/dev/null 2>&1; then
        fail "self-test accepted ZIP output below the portable dist root"
    fi
    [ ! -e "$dist_root/releases" ] \
        || fail "self-test output validation created a directory in dist"

    create_archive "$dist_root" "$archive" "$top_level" 1700000000
    verify_archive "$dist_root" "$archive" "$top_level"
    printf '%s\n' "changed" >> "$dist_root/dinox.exe"
    if verify_archive "$dist_root" "$archive" "$top_level" >/dev/null 2>&1; then
        fail "self-test accepted a ZIP that differs from dist"
    fi

    stale_archive="$temporary/DinoX-stale-windows-x86_64.zip"
    stale_checksum="$stale_archive.sha256"
    printf '%s\n' "stale archive" > "$stale_archive"
    printf '%s\n' "stale checksum" > "$stale_checksum"
    if (
        archive="$stale_archive"
        checksum="$stale_checksum"
        trap cleanup_failed_archive EXIT
        false
    ); then
        fail "self-test cleanup failure path returned success"
    fi
    [ ! -e "$stale_archive" ] \
        || fail "self-test left a stale Windows ZIP after failure"
    [ ! -e "$stale_checksum" ] \
        || fail "self-test left a stale Windows checksum after failure"

    checkout_root="$temporary/Checkout with spaces Юзер"
    git init -q -b master "$checkout_root"
    git -C "$checkout_root" \
        -c user.name="DinoX Self-Test" \
        -c user.email="self-test@example.invalid" \
        commit -q --allow-empty -m "self-test baseline"
    require_clean_checkout "$checkout_root"
    printf '%s\n' "untracked" > "$checkout_root/untracked-source.txt"
    if (require_clean_checkout "$checkout_root") >/dev/null 2>&1; then
        fail "self-test accepted an untracked source file"
    fi

    echo "Self-test OK"
)

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
esac
[ "$#" -le 2 ] || { usage >&2; exit 2; }

DIST_ROOT="${1:-$PROJECT_ROOT/dist}"
OUTPUT_ROOT="${2:-$PROJECT_ROOT}"
[ -d "$DIST_ROOT" ] || fail "Windows dist directory not found: $DIST_ROOT"
require_output_outside_dist "$DIST_ROOT" "$OUTPUT_ROOT"
mkdir -p "$OUTPUT_ROOT"
DIST_ROOT="$(cd "$DIST_ROOT" && pwd)"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd)"

# VERSION is the canonical release version.  Parsing the complete project()
# line is unsafe because its later meson_version field can be captured instead.
version="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION" 2>/dev/null || true)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    || fail "could not read a valid DinoX version from VERSION"
top_level="DinoX-$version-windows-x86_64"
archive="$OUTPUT_ROOT/$top_level.zip"
checksum="$archive.sha256"

# A failed attempt must never leave an older same-name artifact looking like
# the result of the current validation run.
rm -f -- "$archive" "$checksum"
trap cleanup_failed_archive EXIT

bash "$PROJECT_ROOT/scripts/check-windows-dist.sh" "$DIST_ROOT"
source_commit_count="$(grep -c '^source_commit=' "$DIST_ROOT/build-info.txt" || true)"
source_dirty_count="$(grep -c '^source_dirty=' "$DIST_ROOT/build-info.txt" || true)"
[ "$source_commit_count" -eq 1 ] \
    || fail "dist/build-info.txt must contain exactly one source_commit"
[ "$source_dirty_count" -eq 1 ] \
    || fail "dist/build-info.txt must contain exactly one source_dirty"
source_commit="$(sed -n 's/^source_commit=//p' "$DIST_ROOT/build-info.txt")"
source_dirty="$(sed -n 's/^source_dirty=//p' "$DIST_ROOT/build-info.txt")"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] \
    || fail "invalid source_commit in dist/build-info.txt"
current_commit="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
[ "$source_commit" = "$current_commit" ] \
    || fail "Windows dist was not built from the current checkout commit"
[ "$source_dirty" = "false" ] \
    || fail "release ZIP cannot be created from a dirty source build"
require_clean_checkout "$PROJECT_ROOT"
runtime_version="$(
    cd "$DIST_ROOT"
    ./dinox.exe --version | tr -d '\r'
)"
[ "$runtime_version" = "DinoX $version" ] \
    || fail "Windows runtime version mismatch: $runtime_version"
source_epoch="$(git -C "$PROJECT_ROOT" show -s --format=%ct "$source_commit")"
[[ "$source_epoch" =~ ^[0-9]+$ ]] || fail "could not determine source commit time"

create_archive "$DIST_ROOT" "$archive" "$top_level" "$source_epoch"
verify_archive "$DIST_ROOT" "$archive" "$top_level"
archive_size="$(stat -c '%s' "$archive")"
[ "$archive_size" -le "$MAX_ZIP_BYTES" ] \
    || fail "Windows ZIP exceeds $MAX_ZIP_BYTES bytes: $archive_size"
(
    cd "$OUTPUT_ROOT"
    sha256sum "$(basename "$archive")" > "$(basename "$checksum")"
    sha256sum -c "$(basename "$checksum")" >/dev/null
)
trap - EXIT

echo "WINDOWS_ZIP_READY=$archive"
echo "WINDOWS_ZIP_SHA256_READY=$checksum"
