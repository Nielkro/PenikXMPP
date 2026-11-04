#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CUSTOM_DEPENDENCY_PREFIX="${DINOX_CUSTOM_DEPENDENCY_PREFIX:-/opt/dinox-deps}"
CUSTOM_LICENSE_ROOT="${DINOX_CUSTOM_DEPENDENCY_LICENSE_ROOT:-$CUSTOM_DEPENDENCY_PREFIX/share/dinox/custom-dependency-licenses}"
CUSTOM_SOURCE_ROOT="${DINOX_CUSTOM_DEPENDENCY_SOURCE_ROOT:-$CUSTOM_DEPENDENCY_PREFIX/share/dinox/corresponding-sources}"
DISTRIBUTION_SOURCE_ROOT="${DINOX_DISTRIBUTION_SOURCE_ROOT:-$CUSTOM_DEPENDENCY_PREFIX/share/dinox/distribution-sources}"
FFMPEG_RECORDER_VERSION="8.1.2"
FFMPEG_RECORDER_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
X264_RECORDER_COMMIT="b35605ace3ddf7c1a5d67a2eb553f034aef41d55"
X264_RECORDER_SHA256="cd71a7515b0e9a012e1ac9b1f8415bebcaf6fc97d4db32286642ac4c0fbe24f9"
LIBOMEMO_C_README_SHA256="83adeac2f4760208e75160502dce8931a9c918151fb4518ce6e3f011abed2057"
LIBOMEMO_C_ADDITIONAL_PERMISSION='Additional Permissions For Submission to Apple App Store: Provided that you are otherwise in compliance with the GPLv3 for each covered work you convey (including without limitation making the Corresponding Source available in compliance with Section 6 of the GPLv3), Open Whisper Systems and Dino Team also grant you the additional permission to convey through the Apple App Store non-source executable versions of the Program as incorporated into each applicable covered work as Executable Versions only under the Mozilla Public License version 2.0 (https://www.mozilla.org/en-US/MPL/2.0/).'
UBUNTU_SNAPSHOT_APT_ROOT=""
UBUNTU_SNAPSHOT_APT_SOURCE_LIST=""
UBUNTU_SNAPSHOT_APT_ID=""
UBUNTU_SNAPSHOT_APT_INITIALIZED=0
declare -a UBUNTU_SNAPSHOT_APT_ARGS=()

usage() {
    cat <<'USAGE'
Usage:
  scripts/stage-package-licenses.sh --mode deb|appimage --root PACKAGE_ROOT \
    [--source-map FILE] [--project-map FILE]
  scripts/stage-package-licenses.sh --self-test

Stages the DinoX license, exact custom-dependency license trees and the Debian
copyright plus corresponding-source packages for distribution-owned runtime
files copied into a Linux package. FILE contains tab-separated package-relative
destination paths and original host paths. Only entries still present below
PACKAGE_ROOT are used; usrmerge aliases are canonicalized before ownership is
resolved. AppImage PROJECT_MAP is a newline-separated allowlist frozen directly
after Meson install; only matching package-internal sources bypass Debian
ownership, while every external copied runtime remains fail-closed.
Package builders set DINOX_IBUS_COMPAT_PREFIX to stage the separate private
IBus client library's LGPL license and pinned corresponding source archive.
USAGE
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

abs_path() {
    python3 - "$1" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).resolve())
PY
}

validate_ubuntu_apt_snapshot_id() {
    local snapshot_id="${1:-}"

    [[ "$snapshot_id" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]
}

ubuntu_apt_snapshot_id_from_environment() {
    local snapshot_id="${DINOX_UBUNTU_APT_SNAPSHOT:-}"

    validate_ubuntu_apt_snapshot_id "$snapshot_id" || return 1
    printf '%s\n' "$snapshot_id"
}

distribution_source_fetch_mode() {
    local snapshot_id="${DINOX_UBUNTU_APT_SNAPSHOT:-}"

    if [ -z "$snapshot_id" ]; then
        printf 'normal\n'
        return 0
    fi
    validate_ubuntu_apt_snapshot_id "$snapshot_id" || return 1
    printf 'snapshot\n'
}

validate_distribution_source_request() {
    local source_package="${1:-}"
    local source_version="${2:-}"

    [[ "$source_package" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || return 1
    [[ "$source_version" =~ ^[0-9][A-Za-z0-9.+:~_-]*$ ]] || return 1
}

distribution_source_selector() {
    local source_package="${1:-}"
    local source_version="${2:-}"

    validate_distribution_source_request "$source_package" "$source_version" \
        || return 1
    printf '%s=%s\n' "$source_package" "$source_version"
}

write_ubuntu_snapshot_source_list() {
    local snapshot_id="$1"
    local output="$2"

    validate_ubuntu_apt_snapshot_id "$snapshot_id" || return 1
    [ -n "$output" ] || return 1
    install -d -m 0755 "$(dirname "$output")"
    {
        printf 'Types: deb-src\n'
        printf 'URIs: https://snapshot.ubuntu.com/ubuntu/%s\n' "$snapshot_id"
        printf 'Suites: noble noble-updates noble-backports noble-security\n'
        printf 'Components: main universe restricted multiverse\n'
        printf 'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n'
    } > "$output"
}

configure_ubuntu_snapshot_apt_root() {
    local apt_root="$1"
    local snapshot_id="$2"
    local apt_uid apt_gid

    [[ "$apt_root" = /* ]] && [ "$apt_root" != "/" ] \
        && [ -d "$apt_root" ] && [ ! -L "$apt_root" ] \
        || fail "unsafe isolated Ubuntu snapshot APT root: $apt_root"
    validate_ubuntu_apt_snapshot_id "$snapshot_id" \
        || fail "invalid DINOX_UBUNTU_APT_SNAPSHOT: ${snapshot_id:-missing}"

    UBUNTU_SNAPSHOT_APT_ROOT="$apt_root"
    UBUNTU_SNAPSHOT_APT_ID="$snapshot_id"
    UBUNTU_SNAPSHOT_APT_SOURCE_LIST="$apt_root/etc/apt/sources.list.d/dinox-ubuntu-snapshot.sources"
    install -d -m 0755 \
        "$apt_root/var/lib/apt/lists/partial" \
        "$apt_root/var/lib/dpkg" \
        "$apt_root/var/cache/apt/archives/partial" \
        "$apt_root/var/log/apt"
    if [ "$(id -u)" -eq 0 ] \
            && apt_uid="$(id -u _apt 2>/dev/null)" \
            && apt_gid="$(id -g _apt 2>/dev/null)"; then
        chmod 0755 "$apt_root"
        chown "$apt_uid:$apt_gid" \
            "$apt_root/var/lib/apt/lists/partial" \
            "$apt_root/var/cache/apt/archives/partial"
    fi
    : > "$apt_root/var/lib/dpkg/status"
    write_ubuntu_snapshot_source_list \
        "$snapshot_id" "$UBUNTU_SNAPSHOT_APT_SOURCE_LIST" \
        || fail "could not write isolated Ubuntu snapshot APT source configuration"

    UBUNTU_SNAPSHOT_APT_ARGS=(
        -o "Dir::Etc::main=/dev/null"
        -o "Dir::Etc::parts=-"
        -o "Dir::Etc::sourcelist=$UBUNTU_SNAPSHOT_APT_SOURCE_LIST"
        -o "Dir::Etc::sourceparts=-"
        -o "Dir::State=$apt_root/var/lib/apt"
        -o "Dir::State::Lists=$apt_root/var/lib/apt/lists"
        -o "Dir::State::status=$apt_root/var/lib/dpkg/status"
        -o "Dir::Cache=$apt_root/var/cache/apt"
        -o "Dir::Cache::archives=$apt_root/var/cache/apt/archives"
        -o "Dir::Cache::pkgcache=$apt_root/var/cache/apt/pkgcache.bin"
        -o "Dir::Cache::srcpkgcache=$apt_root/var/cache/apt/srcpkgcache.bin"
        -o "Dir::Log=$apt_root/var/log/apt"
        -o "APT::Get::List-Cleanup=0"
        -o "APT::Update::Error-Mode=any"
        -o "Acquire::Retries=3"
        -o "Acquire::http::Timeout=30"
        -o "Acquire::https::Timeout=30"
        -o "Acquire::Check-Valid-Until=false"
    )
}

cleanup_ubuntu_snapshot_apt_root() {
    if [ -n "$UBUNTU_SNAPSHOT_APT_ROOT" ] \
            && [ -d "$UBUNTU_SNAPSHOT_APT_ROOT" ]; then
        rm -rf -- "$UBUNTU_SNAPSHOT_APT_ROOT"
    fi
    UBUNTU_SNAPSHOT_APT_ROOT=""
    UBUNTU_SNAPSHOT_APT_SOURCE_LIST=""
    UBUNTU_SNAPSHOT_APT_ID=""
    UBUNTU_SNAPSHOT_APT_INITIALIZED=0
    UBUNTU_SNAPSHOT_APT_ARGS=()
}

run_ubuntu_snapshot_apt_get() {
    local time_limit

    case "${1:-}" in
        update) time_limit=600s ;;
        source) time_limit=1800s ;;
        *) fail "unsupported isolated Ubuntu snapshot APT operation: ${1:-missing}" ;;
    esac
    command timeout --signal=TERM --kill-after=5s "$time_limit" \
        apt-get "${UBUNTU_SNAPSHOT_APT_ARGS[@]}" "$@"
}

run_ubuntu_snapshot_apt_cache() {
    command apt-cache "${UBUNTU_SNAPSHOT_APT_ARGS[@]}" "$@"
}

update_ubuntu_snapshot_apt_index() {
    local snapshot_id="$UBUNTU_SNAPSHOT_APT_ID"
    local update_status=0
    local max_retries=1
    if [ -z "${DINOX_LICENSE_TEST_MODE:-}" ]; then
        max_retries=10
    fi

    # APT normally tolerates unavailable indexes and exits successfully with
    # partial lists. Error-Mode=any makes that state an initialization failure.
    for ((attempt=1; attempt<=max_retries; attempt++)); do
        if run_ubuntu_snapshot_apt_get update >/dev/null; then
            UBUNTU_SNAPSHOT_APT_INITIALIZED=1
            return 0
        fi
        update_status=$?
        if [ "$attempt" -lt "$max_retries" ]; then
            echo "warning: Ubuntu snapshot update failed (status $update_status), retrying in 5s ($attempt/$max_retries)..." >&2
            sleep 5
        fi
    done

    cleanup_ubuntu_snapshot_apt_root
    fail "could not initialize complete exact Ubuntu snapshot source index: $snapshot_id (APT exit $update_status)"
}

initialize_ubuntu_snapshot_apt() {
    local snapshot_id

    snapshot_id="$(ubuntu_apt_snapshot_id_from_environment || true)"
    [ -n "$snapshot_id" ] \
        || fail "exact Debian source unavailable and DINOX_UBUNTU_APT_SNAPSHOT is missing or invalid"

    if [ "$UBUNTU_SNAPSHOT_APT_INITIALIZED" -eq 1 ]; then
        [ "$snapshot_id" = "$UBUNTU_SNAPSHOT_APT_ID" ] \
            || fail "DINOX_UBUNTU_APT_SNAPSHOT changed during package staging"
        return 0
    fi

    command -v apt-get >/dev/null 2>&1 && command -v apt-cache >/dev/null 2>&1 \
        && command -v timeout >/dev/null 2>&1 \
        || fail "apt-get, apt-cache and timeout are required for the Ubuntu snapshot source fallback"
    [ -s /usr/share/keyrings/ubuntu-archive-keyring.gpg ] \
        || fail "Ubuntu archive keyring is required for the Ubuntu snapshot source fallback"

    UBUNTU_SNAPSHOT_APT_ROOT="$(mktemp -d)"
    configure_ubuntu_snapshot_apt_root "$UBUNTU_SNAPSHOT_APT_ROOT" "$snapshot_id"
    update_ubuntu_snapshot_apt_index
}

stage_distribution_source_from_ubuntu_snapshot() {
    local source_root="$1"
    local source_package="$2"
    local source_version="$3"
    local selector

    selector="$(distribution_source_selector "$source_package" "$source_version" || true)"
    [ -n "$selector" ] \
        || fail "unsafe exact distribution source request: $source_package=$source_version"
    initialize_ubuntu_snapshot_apt

    run_ubuntu_snapshot_apt_cache showsrc "$source_package" 2>/dev/null \
        | awk -v expected="$source_version" \
            '$1 == "Version:" && $2 == expected { found = 1 } END { exit(found ? 0 : 1) }' \
        || { echo "exact Ubuntu snapshot source index is missing: $source_package=$source_version" >&2; return 1; }
    local max_retries=1
    if [ -z "${DINOX_LICENSE_TEST_MODE:-}" ]; then
        max_retries=10
    fi
    local downloaded=0
    for ((attempt=1; attempt<=max_retries; attempt++)); do
        if (cd "$source_root" && run_ubuntu_snapshot_apt_get source \
                --download-only --only-source "$selector" >/dev/null); then
            downloaded=1
            break
        fi
        if [ "$attempt" -lt "$max_retries" ]; then
            echo "warning: download $source_package failed, retrying in 5s ($attempt/$max_retries)..." >&2
            sleep 5
        fi
    done
    if [ "$downloaded" -eq 0 ]; then
        echo "exact Ubuntu snapshot source unavailable: $source_package=$source_version" >&2
        return 1
    fi
}

copy_project_license() {
    local root="$1"
    local license_root="$root/usr/share/licenses/dinox/dinox"

    install -d -m 0755 "$license_root"
    install -m 0644 "$PROJECT_ROOT/LICENSE" "$license_root/LICENSE"
    install -m 0644 "$PROJECT_ROOT/NOTICE" "$license_root/NOTICE"
    install -m 0644 "$PROJECT_ROOT/AUTHORS" "$license_root/AUTHORS"
}

require_libomemo_additional_permission() {
    local component_root="$1"
    local readme="$component_root/files/README.md"

    [ -s "$component_root/METADATA" ] \
        || fail "libomemo-c license metadata missing: $component_root/METADATA"
    grep -Fx 'additional_permission_file=files/README.md' "$component_root/METADATA" >/dev/null \
        || fail "libomemo-c metadata does not identify its additional permission"
    grep -Fx "additional_permission_sha256=$LIBOMEMO_C_README_SHA256" \
        "$component_root/METADATA" >/dev/null \
        || fail "libomemo-c metadata has wrong additional-permission checksum"
    [ -s "$readme" ] || fail "libomemo-c additional-permission README is missing: $readme"
    printf '%s  %s\n' "$LIBOMEMO_C_README_SHA256" "$readme" | sha256sum -c - >/dev/null \
        || fail "libomemo-c additional-permission README checksum mismatch"
    grep -Fx "$LIBOMEMO_C_ADDITIONAL_PERMISSION" "$readme" >/dev/null \
        || fail "libomemo-c App Store additional permission is missing"
}

copy_custom_dependency_licenses() {
    local root="$1"
    local mode="$2"
    local destination="$root/usr/share/licenses/dinox/custom-dependencies"
    local component
    local first_license
    local components=(
        sqlcipher
        libnice
        protobuf-c
        libomemo-c
        cjson
        mosquitto
        tor
        lyrebird
    )
    if [ "$mode" = "appimage" ]; then
        components+=(
            recorder-ffmpeg
            recorder-x264
        )
    fi

    require_libomemo_additional_permission "$CUSTOM_LICENSE_ROOT/libomemo-c"
    install -d -m 0755 "$destination"
    for component in "${components[@]}"; do
        [ -s "$CUSTOM_LICENSE_ROOT/$component/METADATA" ] \
            || fail "custom dependency metadata missing: $CUSTOM_LICENSE_ROOT/$component/METADATA"
        first_license="$(find "$CUSTOM_LICENSE_ROOT/$component/files" -type f -size +0c -print -quit 2>/dev/null || true)"
        [ -n "$first_license" ] \
            || fail "custom dependency license files missing: $CUSTOM_LICENSE_ROOT/$component/files"
        install -d -m 0755 "$destination/$component"
        cp -a "$CUSTOM_LICENSE_ROOT/$component/." "$destination/$component/"
    done
    require_libomemo_additional_permission "$destination/libomemo-c"
}

copy_recorder_corresponding_sources() {
    local root="$1"
    local mode="$2"
    local destination="$root/usr/share/licenses/dinox/corresponding-sources"
    local component version archive checksum source_root source_archive

    [ "$mode" = "appimage" ] || return 0
    install -d -m 0755 "$destination"

    for component in recorder-ffmpeg recorder-x264; do
        case "$component" in
            recorder-ffmpeg)
                version="$FFMPEG_RECORDER_VERSION"
                archive="ffmpeg-$FFMPEG_RECORDER_VERSION.tar.xz"
                checksum="$FFMPEG_RECORDER_SHA256"
                ;;
            recorder-x264)
                version="$X264_RECORDER_COMMIT"
                archive="x264-$X264_RECORDER_COMMIT.tar.gz"
                checksum="$X264_RECORDER_SHA256"
                ;;
        esac
        source_root="$CUSTOM_SOURCE_ROOT/$component"
        source_archive="$source_root/$archive"

        [ -s "$source_root/METADATA" ] \
            || fail "$component corresponding-source metadata missing: $source_root/METADATA"
        [ -s "$source_archive" ] \
            || fail "$component corresponding-source archive missing: $source_archive"
        grep -Fx "component=$component" "$source_root/METADATA" >/dev/null \
            || fail "$component corresponding-source component mismatch"
        grep -Fx "version=$version" "$source_root/METADATA" >/dev/null \
            || fail "$component corresponding-source version mismatch"
        grep -Fx "archive=$archive" "$source_root/METADATA" >/dev/null \
            || fail "$component corresponding-source archive mismatch"
        grep -Fx "checksum_algorithm=sha256" "$source_root/METADATA" >/dev/null \
            || fail "$component corresponding-source checksum algorithm mismatch"
        grep -Fx "checksum=$checksum" "$source_root/METADATA" >/dev/null \
            || fail "$component corresponding-source checksum mismatch"
        grep -Fx "license_expression=GPL-2.0-or-later" "$source_root/METADATA" >/dev/null \
            || fail "$component corresponding-source license mismatch"
        printf '%s  %s\n' "$checksum" "$source_archive" | sha256sum -c - >/dev/null \
            || fail "$component corresponding-source archive failed checksum validation"

        install -d -m 0755 "$destination/$component"
        install -m 0644 "$source_root/METADATA" "$destination/$component/METADATA"
        install -m 0644 "$source_archive" "$destination/$component/$archive"
    done
}

distribution_source_files() {
    local dsc="$1"
    awk '
        /^Checksums-Sha256:/ { in_checksums = 1; next }
        in_checksums && /^ / { print $3; next }
        in_checksums { exit }
    ' "$dsc"
}

validate_distribution_source_tree() {
    local source_root="$1"
    local expected_source_package="$2"
    local expected_source_version="$3"
    local listed_files actual_files expected_files dsc dsc_source dsc_version extract_root

    [ -s "$source_root/METADATA" ] \
        || fail "$expected_source_package source metadata missing: $source_root/METADATA"
    [ -s "$source_root/SHA256SUMS" ] \
        || fail "$expected_source_package source checksums missing: $source_root/SHA256SUMS"
    grep -Fx "source_package=$expected_source_package" "$source_root/METADATA" >/dev/null \
        || fail "$expected_source_package source-package metadata mismatch"
    grep -Fx "source_version=$expected_source_version" "$source_root/METADATA" >/dev/null \
        || fail "$expected_source_package source-version metadata mismatch"
    grep -Fx 'source_format=debian-source-package' "$source_root/METADATA" >/dev/null \
        || fail "$expected_source_package source-format metadata mismatch"

    listed_files="$(awk '{ name = $2; sub(/^\*/, "", name); print name }' \
        "$source_root/SHA256SUMS" | sort -u)"
    actual_files="$(find "$source_root" -maxdepth 1 -type f \
        ! -name METADATA ! -name SHA256SUMS -printf '%f\n' | sort -u)"
    [ -n "$actual_files" ] && [ "$listed_files" = "$actual_files" ] \
        || fail "$expected_source_package source checksum inventory mismatch"
    (cd "$source_root" && sha256sum -c SHA256SUMS >/dev/null) \
        || fail "$expected_source_package source checksum validation failed"

    [ "$(find "$source_root" -maxdepth 1 -type f -name '*.dsc' | wc -l)" -eq 1 ] \
        || fail "$expected_source_package source tree must contain exactly one .dsc"
    dsc="$(find "$source_root" -maxdepth 1 -type f -name '*.dsc' -print -quit)"
    dsc_source="$(sed -n 's/^Source:[[:space:]]*//p' "$dsc" | tail -1)"
    dsc_version="$(sed -n 's/^Version:[[:space:]]*//p' "$dsc" | tail -1)"
    [ "$dsc_source" = "$expected_source_package" ] \
        || fail "$expected_source_package .dsc source mismatch: ${dsc_source:-missing}"
    [ "$dsc_version" = "$expected_source_version" ] \
        || fail "$expected_source_package .dsc version mismatch: ${dsc_version:-missing}"

    expected_files="$({
        basename "$dsc"
        distribution_source_files "$dsc"
    } | sort -u)"
    [ "$expected_files" = "$actual_files" ] \
        || fail "$expected_source_package source tree contains files outside its .dsc payload"

    distribution_source_files "$dsc" | grep -q . \
        || fail "$expected_source_package .dsc has no SHA256 payload inventory"
    while IFS= read -r payload; do
        [[ "$payload" =~ ^[A-Za-z0-9][A-Za-z0-9.+:~_-]*$ ]] \
            || fail "$expected_source_package .dsc contains unsafe payload path: $payload"
    done < <(distribution_source_files "$dsc")
    (cd "$source_root" && awk '
        /^Checksums-Sha256:/ { in_checksums = 1; next }
        in_checksums && /^ / { print $1 "  " $3; next }
        in_checksums { exit }
    ' "$(basename "$dsc")" | sha256sum -c - >/dev/null) \
        || fail "$expected_source_package .dsc payload checksum validation failed"
    [ "$(find "$source_root" -maxdepth 1 -type f \
        \( -name '*.tar.gz' -o -name '*.tar.bz2' -o -name '*.tar.lzma' -o -name '*.tar.xz' -o -name '*.tar.zst' \) \
        | wc -l)" -ge 1 ] \
        || fail "$expected_source_package source archive missing"

    command -v dpkg-source >/dev/null 2>&1 \
        || fail "dpkg-source is required to validate corresponding sources"
    extract_root="$(mktemp -d)"
    if ! dpkg-source --no-check -x "$dsc" "$extract_root/source" >/dev/null 2>&1; then
        rm -rf "$extract_root"
        fail "$expected_source_package source package is not extractable"
    fi
    [ -d "$extract_root/source" ] \
        || { rm -rf "$extract_root"; fail "$expected_source_package source extraction produced no tree"; }
    rm -rf "$extract_root"
}

write_distribution_source_metadata() {
    local source_root="$1"
    local source_package="$2"
    local source_version="$3"
    local binary_packages="$4"

    find "$source_root" -maxdepth 1 -type f \
        ! -name METADATA ! -name SHA256SUMS -printf '%f\0' \
        | sort -z \
        | (cd "$source_root" && xargs -0 sha256sum) > "$source_root/SHA256SUMS"
    {
        printf 'source_package=%s\n' "$source_package"
        printf 'source_version=%s\n' "$source_version"
        printf 'binary_packages=%s\n' "$binary_packages"
        printf 'source_format=debian-source-package\n'
    } > "$source_root/METADATA"
}

stage_distribution_source_pair() {
    local destination_root="$1"
    local source_package="$2"
    local source_version="$3"
    local binary_packages="$4"
    local cached_source="$DISTRIBUTION_SOURCE_ROOT/$source_package"
    local work_root source_root selector fetch_mode normal_source_downloaded=0
    local apt_uid apt_gid

    validate_distribution_source_request "$source_package" "$source_version" \
        || fail "unsafe exact distribution source request: $source_package=$source_version"
    selector="$(distribution_source_selector "$source_package" "$source_version")"

    work_root="$(mktemp -d)"
    source_root="$work_root/$source_package"
    install -d -m 0755 "$source_root"
    if [ "$(id -u)" -eq 0 ] \
            && apt_uid="$(id -u _apt 2>/dev/null)" \
            && apt_gid="$(id -g _apt 2>/dev/null)"; then
        # apt-get source downloads through the unprivileged _apt helper.  The
        # default 0700 mktemp parent otherwise forces APT to fall back to an
        # unsandboxed root download for every corresponding-source archive.
        chmod 0755 "$work_root"
        chown "$apt_uid:$apt_gid" "$source_root"
    fi

    if [ -s "$cached_source/METADATA" ] \
            && { grep -Fx "source_package=$source_package" "$cached_source/METADATA" >/dev/null; } \
        && { grep -Fx "source_version=$source_version" "$cached_source/METADATA" >/dev/null \
            || grep -Fx "version=$source_version" "$cached_source/METADATA" >/dev/null; }; then
        [ -s "$cached_source/SHA256SUMS" ] \
            || { rm -rf "$work_root"; fail "$source_package cached source checksums missing"; }
        (cd "$cached_source" && sha256sum -c SHA256SUMS >/dev/null) \
            || { rm -rf "$work_root"; fail "$source_package cached source checksum validation failed"; }
        find "$cached_source" -maxdepth 1 -type f \
            ! -name METADATA ! -name SHA256SUMS -exec cp -a '{}' "$source_root/" ';'
    else
        fetch_mode="$(distribution_source_fetch_mode)" \
            || { rm -rf "$work_root"; fail "invalid DINOX_UBUNTU_APT_SNAPSHOT: ${DINOX_UBUNTU_APT_SNAPSHOT:-missing}"; }
        command -v apt-get >/dev/null 2>&1 && command -v apt-cache >/dev/null 2>&1 \
            || { rm -rf "$work_root"; fail "apt-get and apt-cache are required for exact Debian corresponding sources"; }
        local downloaded_source=0
        if [ "$fetch_mode" = "snapshot" ]; then
            # The package-builder snapshot is authoritative. Probing the moving
            # Ubuntu archive first only produces 404s after superseded pool
            # files have been removed.
            echo "Using pinned Ubuntu snapshot source: $source_package=$source_version"
            if stage_distribution_source_from_ubuntu_snapshot \
                "$source_root" "$source_package" "$source_version"; then
                downloaded_source=1
            else
                echo "warning: exact snapshot missing $source_package=$source_version, trying live archive..." >&2
            fi
        fi
        if [ "$downloaded_source" -eq 0 ]; then
            if ! apt-cache showsrc "$source_package" >/dev/null 2>&1; then
                apt-get update >/dev/null 2>&1 || true
            fi
            if apt-cache showsrc "$source_package" 2>/dev/null \
                    | awk -v expected="$source_version" \
                        '$1 == "Version:" && $2 == expected { found = 1 } END { exit(found ? 0 : 1) }'; then
                if (cd "$source_root" && apt-get source --download-only \
                        --only-source "$selector" >/dev/null); then
                    downloaded_source=1
                fi
            fi
        fi
        if [ "$downloaded_source" -eq 0 ]; then
            rm -rf "$work_root"
            fail "exact source unavailable in snapshot and normal APT: $source_package=$source_version"
        fi
    fi

    if [ "$(id -u)" -eq 0 ]; then
        chown -R 0:0 "$work_root"
    fi
    write_distribution_source_metadata \
        "$source_root" "$source_package" "$source_version" "$binary_packages"
    validate_distribution_source_tree "$source_root" "$source_package" "$source_version"
    install -d -m 0755 "$destination_root/$source_package"
    cp -a "$source_root/." "$destination_root/$source_package/"
    if [ -d "$DISTRIBUTION_SOURCE_ROOT" ] && [ -w "$DISTRIBUTION_SOURCE_ROOT" ]; then
        install -d -m 0755 "$DISTRIBUTION_SOURCE_ROOT/$source_package"
        cp -a "$source_root/." "$DISTRIBUTION_SOURCE_ROOT/$source_package/" 2>/dev/null || true
    fi
    rm -rf "$work_root"
}

copy_distribution_corresponding_sources() {
    local root="$1"
    local mode="$2"
    local inventory="$root/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv"
    local destination="$root/usr/share/licenses/dinox/corresponding-sources/distribution"
    local pairs source_package source_version binary_packages

    [ "$mode" = "appimage" ] || return 0
    [ -s "$inventory" ] && [ "$(wc -l < "$inventory")" -gt 1 ] \
        || fail "AppImage distribution runtime inventory is empty"

    pairs="$(mktemp)"
    tail -n +2 "$inventory" | cut -f6,7 | sort -u > "$pairs"
    awk -F '\t' '
        seen[$1] && seen[$1] != $2 { exit 1 }
        { seen[$1] = $2 }
    ' "$pairs" \
        || { rm -f "$pairs"; fail "one Debian source package maps to multiple exact source versions"; }

    rm -rf "$destination"
    install -d -m 0755 "$destination"
    while IFS=$'\t' read -r source_package source_version; do
        [ -n "$source_package" ] || continue
        binary_packages="$(awk -F '\t' \
            -v source_package="$source_package" -v source_version="$source_version" \
            '$6 == source_package && $7 == source_version { print $3 }' "$inventory" \
            | sort -u | paste -sd, -)"
        [ -n "$binary_packages" ] \
            || { rm -f "$pairs"; fail "no binary package maps to $source_package=$source_version"; }
        stage_distribution_source_pair \
            "$destination" "$source_package" "$source_version" "$binary_packages"
    done < "$pairs"
    rm -f "$pairs"
}

run_dpkg_query() {
    command dpkg-query "$@"
}

canonical_package_source_path() {
    local path="$1"
    local canonical=""

    canonical="$(readlink -f -- "$path" 2>/dev/null || true)"
    [ -n "$canonical" ] && [ -e "$canonical" ] || return 1
    printf '%s\n' "$canonical"
}

parse_dpkg_search_owner() {
    local expected_path="$1"
    local search_output="$2"
    local line candidate owned_path owner=""

    while IFS= read -r line; do
        case "$line" in
            "diversion by "*|"local diversion "*)
                continue
                ;;
        esac
        if [[ "$line" =~ ^([a-z0-9][a-z0-9+.-]*(:[a-z0-9][a-z0-9-]*)?):[[:space:]](.+)$ ]]; then
            candidate="${BASH_REMATCH[1]}"
            owned_path="${BASH_REMATCH[3]}"
            [ "$owned_path" = "$expected_path" ] || continue
            if [ -n "$owner" ] && [ "$owner" != "$candidate" ]; then
                return 1
            fi
            owner="$candidate"
        fi
    done <<< "$search_output"

    [ -n "$owner" ] || return 1
    printf '%s\n' "$owner"
}

validate_dpkg_binary_package_owner() {
    local owner="$1"
    local metadata="$2"
    local binary_package package_name architecture status extra=""

    case "$metadata" in
        *$'\n'*) return 1 ;;
    esac
    IFS=$'\t' read -r binary_package package_name architecture status extra <<< "$metadata"
    [ -z "$extra" ] || return 1
    [[ "$binary_package" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9][a-z0-9-]*)?$ ]] || return 1
    [[ "$package_name" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || return 1
    [[ "$architecture" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
    [ "$binary_package" = "$owner" ] || return 1
    case "$binary_package" in
        "$package_name"|"$package_name:$architecture") ;;
        *) return 1 ;;
    esac
    [ "$status" = "install ok installed" ] || return 1
}

usrmerge_alias_for_canonical_path() {
    local canonical="$1"
    local usr_root="${2:-/usr}"
    local legacy_root="${3:-}"
    local suffix alias canonical_alias

    case "$canonical" in
        "$usr_root"/bin/*|"$usr_root"/sbin/*|"$usr_root"/lib/*|"$usr_root"/lib64/*)
            suffix="${canonical#"$usr_root"}"
            ;;
        *)
            return 1
            ;;
    esac
    alias="$legacy_root$suffix"
    [ -e "$alias" ] || return 1
    canonical_alias="$(canonical_package_source_path "$alias")" || return 1
    [ "$canonical_alias" = "$canonical" ] || return 1
    printf '%s\n' "$alias"
}

package_owner_for_registered_path() {
    local registered_path="$1"
    local search_output owner metadata

    search_output="$(run_dpkg_query -S -- "$registered_path" 2>/dev/null)" || return 1
    owner="$(parse_dpkg_search_owner "$registered_path" "$search_output")" || return 1
    metadata="$(run_dpkg_query -W \
        -f='${binary:Package}\t${Package}\t${Architecture}\t${Status}' \
        "$owner" 2>/dev/null)" || return 1
    validate_dpkg_binary_package_owner "$owner" "$metadata" || return 1
    printf '%s\n' "$owner"
}

package_owner_for_path() {
    local path="$1"
    local usr_root="${2:-/usr}"
    local legacy_root="${3:-}"
    local canonical="" alias="" canonical_owner="" alias_owner="" owner=""

    canonical="$(canonical_package_source_path "$path")" || return 1
    canonical_owner="$(package_owner_for_registered_path "$canonical" || true)"

    alias="$(usrmerge_alias_for_canonical_path \
        "$canonical" "$usr_root" "$legacy_root" || true)"
    if [ -n "$alias" ]; then
        alias_owner="$(package_owner_for_registered_path "$alias" || true)"
    fi

    if [ -n "$canonical_owner" ] && [ -n "$alias_owner" ] \
            && [ "$canonical_owner" != "$alias_owner" ]; then
        return 1
    fi
    owner="${canonical_owner:-$alias_owner}"
    [ -n "$owner" ] || return 1
    printf '%s\n' "$owner"
}

self_test_ubuntu_snapshot_apt() (
    # These commands are fixtures only: no host APT update or network request
    # may run while checking partial indexes, retries and the timeout wrapper.
    trap - EXIT
    local fixture="$1/snapshot-apt-regressions"
    local snapshot_id="$2"
    local mode apt_root failure_state source_version apt_calls expected_calls
    mkdir -p "$fixture/bin"
    cat > "$fixture/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$DINOX_LICENSE_TEST_LOG/timeout.args"
[ "$1" = "--signal=TERM" ] && [ "$2" = "--kill-after=5s" ]
shift 3
if [ "$DINOX_LICENSE_TEST_MODE" = timeout ]; then
    exit 124
fi
exec "$@"
MOCK
    cat > "$fixture/bin/apt-get" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$DINOX_LICENSE_TEST_LOG/apt-get.args"
printf 'request\n' >> "$DINOX_LICENSE_TEST_LOG/apt-get.calls"
strict=0
for arg in "$@"; do
    if [ "$arg" = "APT::Update::Error-Mode=any" ]; then strict=1; fi
done
case "$DINOX_LICENSE_TEST_MODE" in
    partial)
        printf 'partial source list\n' > "$DINOX_LICENSE_TEST_ROOT/var/lib/apt/lists/partial/fixture"
        printf 'W: Failed to fetch fixture: 503 Service Unavailable\n' >&2
        # Match APT's legacy behavior: a partial update is otherwise exit 0.
        if [ "$strict" -eq 1 ]; then exit 100; fi
        ;;
    failed)
        printf 'E: Failed to fetch fixture: 502 Bad Gateway\n' >&2
        exit 100
        ;;
esac
MOCK
    cat > "$fixture/bin/apt-cache" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$DINOX_LICENSE_TEST_LOG/apt-cache.args"
printf 'Version: %s\n' "$DINOX_LICENSE_TEST_SOURCE_VERSION"
MOCK
    chmod +x "$fixture/bin/timeout" "$fixture/bin/apt-get" "$fixture/bin/apt-cache"
    export PATH="$fixture/bin:$PATH"
    export DINOX_UBUNTU_APT_SNAPSHOT="$snapshot_id"
    export DINOX_LICENSE_TEST_LOG DINOX_LICENSE_TEST_MODE DINOX_LICENSE_TEST_ROOT
    export DINOX_LICENSE_TEST_SOURCE_VERSION=1.24.2-1ubuntu1.4

    for mode in partial failed timeout; do
        apt_root="$fixture/$mode-apt"
        DINOX_LICENSE_TEST_LOG="$fixture/$mode-log"
        DINOX_LICENSE_TEST_MODE="$mode"
        DINOX_LICENSE_TEST_ROOT="$apt_root"
        mkdir -p "$apt_root" "$DINOX_LICENSE_TEST_LOG"
        configure_ubuntu_snapshot_apt_root "$apt_root" "$snapshot_id"
        failure_state="$DINOX_LICENSE_TEST_LOG/failure-state"
        if (
            trap 'printf "%s\n" "$UBUNTU_SNAPSHOT_APT_INITIALIZED" "$UBUNTU_SNAPSHOT_APT_ROOT" "$UBUNTU_SNAPSHOT_APT_ID" "${#UBUNTU_SNAPSHOT_APT_ARGS[@]}" > "$failure_state"' EXIT
            update_ubuntu_snapshot_apt_index
        ) > "$DINOX_LICENSE_TEST_LOG/update.log" 2>&1; then
            fail "self-test cached a failed or incomplete Ubuntu snapshot update: $mode"
        fi
        [ "$(cat "$failure_state")" = "$(printf '0\n\n\n0')" ] \
            && [ ! -e "$apt_root" ] \
            || fail "self-test did not clear failed Ubuntu snapshot APT state: $mode"
        grep -F "could not initialize complete exact Ubuntu snapshot source index: $snapshot_id" \
            "$DINOX_LICENSE_TEST_LOG/update.log" >/dev/null \
            || fail "self-test lost the actual Ubuntu snapshot update failure: $mode"
        printf '%s\n' --signal=TERM --kill-after=5s 600s apt-get \
            "${UBUNTU_SNAPSHOT_APT_ARGS[@]}" update \
            > "$DINOX_LICENSE_TEST_LOG/expected-timeout.args"
        cmp -s "$DINOX_LICENSE_TEST_LOG/expected-timeout.args" \
            "$DINOX_LICENSE_TEST_LOG/timeout.args" \
            || fail "self-test isolated Ubuntu snapshot update wrapper mismatch: $mode"
    done

    # Reconfigure after an incomplete attempt, then prove only a complete
    # successful update becomes reusable by exact source downloads.
    apt_root="$fixture/success-apt"
    DINOX_LICENSE_TEST_LOG="$fixture/success-log"
    DINOX_LICENSE_TEST_MODE=success
    DINOX_LICENSE_TEST_ROOT="$apt_root"
    mkdir -p "$apt_root" "$DINOX_LICENSE_TEST_LOG" "$fixture/source"
    configure_ubuntu_snapshot_apt_root "$apt_root" "$snapshot_id"
    update_ubuntu_snapshot_apt_index
    [ "$UBUNTU_SNAPSHOT_APT_INITIALIZED" -eq 1 ] \
        || fail "self-test did not cache a complete Ubuntu snapshot update"
    printf '%s\n' "${UBUNTU_SNAPSHOT_APT_ARGS[@]}" update \
        > "$DINOX_LICENSE_TEST_LOG/expected-update.args"
    cmp -s "$DINOX_LICENSE_TEST_LOG/expected-update.args" \
        "$DINOX_LICENSE_TEST_LOG/apt-get.args" \
        || fail "self-test isolated Ubuntu snapshot APT update arguments mismatch"
    initialize_ubuntu_snapshot_apt
    [ "$(wc -l < "$DINOX_LICENSE_TEST_LOG/apt-get.calls")" -eq 1 ] \
        || fail "self-test repeated a complete cached Ubuntu snapshot update"
    if (DINOX_UBUNTU_APT_SNAPSHOT=20260722T000000Z \
            initialize_ubuntu_snapshot_apt) >/dev/null 2>&1; then
        fail "self-test reused source indexes for a changed Ubuntu snapshot ID"
    fi
    stage_distribution_source_from_ubuntu_snapshot \
        "$fixture/source" gst-plugins-good1.0 "$DINOX_LICENSE_TEST_SOURCE_VERSION"
    printf '%s\n' --signal=TERM --kill-after=5s 1800s apt-get \
        "${UBUNTU_SNAPSHOT_APT_ARGS[@]}" source --download-only --only-source \
        "gst-plugins-good1.0=$DINOX_LICENSE_TEST_SOURCE_VERSION" \
        > "$DINOX_LICENSE_TEST_LOG/expected-source-timeout.args"
    cmp -s "$DINOX_LICENSE_TEST_LOG/expected-source-timeout.args" \
        "$DINOX_LICENSE_TEST_LOG/timeout.args" \
        || fail "self-test isolated Ubuntu snapshot source timeout wrapper mismatch"
    printf '%s\n' "${UBUNTU_SNAPSHOT_APT_ARGS[@]}" source \
        --download-only --only-source "gst-plugins-good1.0=$DINOX_LICENSE_TEST_SOURCE_VERSION" \
        > "$DINOX_LICENSE_TEST_LOG/expected-source.args"
    cmp -s "$DINOX_LICENSE_TEST_LOG/expected-source.args" \
        "$DINOX_LICENSE_TEST_LOG/apt-get.args" \
        || fail "self-test lost the exact Ubuntu snapshot source selector"
    printf '%s\n' "${UBUNTU_SNAPSHOT_APT_ARGS[@]}" showsrc gst-plugins-good1.0 \
        > "$DINOX_LICENSE_TEST_LOG/expected-cache.args"
    cmp -s "$DINOX_LICENSE_TEST_LOG/expected-cache.args" \
        "$DINOX_LICENSE_TEST_LOG/apt-cache.args" \
        || fail "self-test Ubuntu snapshot source lookup escaped its isolated APT root"
    [ "$(wc -l < "$DINOX_LICENSE_TEST_LOG/apt-get.calls")" -eq 2 ] \
        || fail "self-test repeated index initialization while downloading exact sources"

    source_version="$DINOX_LICENSE_TEST_SOURCE_VERSION"
    for mode in failed timeout; do
        DINOX_LICENSE_TEST_MODE="$mode"
        apt_calls="$(wc -l < "$DINOX_LICENSE_TEST_LOG/apt-get.calls")"
        expected_calls="$apt_calls"
        if [ "$mode" = failed ]; then expected_calls=$((apt_calls + 1)); fi
        if (stage_distribution_source_from_ubuntu_snapshot \
                "$fixture/source" gst-plugins-good1.0 "$source_version") \
                > "$DINOX_LICENSE_TEST_LOG/source-$mode.log" 2>&1; then
            fail "self-test accepted a failed or timed-out exact Ubuntu snapshot source download: $mode"
        fi
        grep -F "exact Ubuntu snapshot source unavailable: gst-plugins-good1.0=$source_version" \
            "$DINOX_LICENSE_TEST_LOG/source-$mode.log" >/dev/null \
            || fail "self-test lost the exact Ubuntu snapshot source download failure: $mode"
        cmp -s "$DINOX_LICENSE_TEST_LOG/expected-source-timeout.args" \
            "$DINOX_LICENSE_TEST_LOG/timeout.args" \
            || fail "self-test failed source download escaped its bounded snapshot wrapper: $mode"
        [ "$(wc -l < "$DINOX_LICENSE_TEST_LOG/apt-get.calls")" -eq "$expected_calls" ] \
            || fail "self-test attempted an extra source download or moving-mirror fallback: $mode"
        if [ "$mode" = failed ]; then
            cmp -s "$DINOX_LICENSE_TEST_LOG/expected-source.args" \
                "$DINOX_LICENSE_TEST_LOG/apt-get.args" \
                || fail "self-test failed source download changed its exact snapshot request"
        fi
    done

    DINOX_LICENSE_TEST_MODE=success
    DINOX_LICENSE_TEST_SOURCE_VERSION=1.24.2-1ubuntu1.5
    apt_calls="$(wc -l < "$DINOX_LICENSE_TEST_LOG/apt-get.calls")"
    rm -f "$DINOX_LICENSE_TEST_LOG/timeout.args"
    if (stage_distribution_source_from_ubuntu_snapshot \
            "$fixture/source" gst-plugins-good1.0 "$source_version") \
            > "$DINOX_LICENSE_TEST_LOG/source-version-missing.log" 2>&1; then
        fail "self-test accepted a Ubuntu snapshot index without the exact source version"
    fi
    grep -F "exact Ubuntu snapshot source index is missing: gst-plugins-good1.0=$source_version" \
        "$DINOX_LICENSE_TEST_LOG/source-version-missing.log" >/dev/null \
        || fail "self-test lost the missing exact Ubuntu snapshot source version"
    [ ! -e "$DINOX_LICENSE_TEST_LOG/timeout.args" ] \
        && [ "$(wc -l < "$DINOX_LICENSE_TEST_LOG/apt-get.calls")" -eq "$apt_calls" ] \
        || fail "self-test downloaded sources or tried a moving mirror after an exact-version mismatch"
    cleanup_ubuntu_snapshot_apt_root
)

run_self_test() {
    local tmp self_test_target alias expected_owner owner cleanup_command fixture_app fixture_source
    local debian_fixture project_app project_map different_target
    local snapshot_id snapshot_root snapshot_source_list actual_snapshot_source_list
    local selector invalid index fetch_mode
    local host_alias="/lib/x86_64-linux-gnu/libreadline.so.8"
    local host_owner="libreadline8t64:$(dpkg --print-architecture 2>/dev/null || true)"
    local host_lzo_alias="/lib/x86_64-linux-gnu/liblzo2.so.2.0.0"
    local host_lzo_owner="liblzo2-2:$(dpkg --print-architecture 2>/dev/null || true)"
    local host_lzo_canonical lzo_app
    local self_test_query_mode="valid"
    local -a expected_snapshot_apt_args

    tmp="$(mktemp -d)"
    printf -v cleanup_command 'rm -rf -- %q' "$tmp"
    trap "$cleanup_command; cleanup_ubuntu_snapshot_apt_root" EXIT

    snapshot_id="20260721T000000Z"
    validate_ubuntu_apt_snapshot_id "$snapshot_id" \
        || fail "self-test rejected the documented Ubuntu snapshot ID format"
    for invalid in \
        "" "20260721" "20260721T000000" "20260721t000000Z" \
        "2026-07-21T000000Z" "20260721T000000Z/../current"; do
        if validate_ubuntu_apt_snapshot_id "$invalid"; then
            fail "self-test accepted unsafe Ubuntu snapshot ID: ${invalid:-empty}"
        fi
    done
    [ "$(DINOX_UBUNTU_APT_SNAPSHOT="$snapshot_id" \
            ubuntu_apt_snapshot_id_from_environment)" = "$snapshot_id" ] \
        || fail "self-test did not read the Ubuntu snapshot ID from its environment"
    if DINOX_UBUNTU_APT_SNAPSHOT=latest \
            ubuntu_apt_snapshot_id_from_environment >/dev/null 2>&1; then
        fail "self-test accepted an invalid environment snapshot ID"
    fi
    if DINOX_UBUNTU_APT_SNAPSHOT= \
            ubuntu_apt_snapshot_id_from_environment >/dev/null 2>&1; then
        fail "self-test invented a default Ubuntu snapshot ID"
    fi
    fetch_mode="$(DINOX_UBUNTU_APT_SNAPSHOT="$snapshot_id" \
        distribution_source_fetch_mode)"
    [ "$fetch_mode" = "snapshot" ] \
        || fail "self-test did not prefer the configured Ubuntu snapshot"
    fetch_mode="$(DINOX_UBUNTU_APT_SNAPSHOT= \
        distribution_source_fetch_mode)"
    [ "$fetch_mode" = "normal" ] \
        || fail "self-test did not preserve normal APT without a snapshot"
    if DINOX_UBUNTU_APT_SNAPSHOT=latest \
            distribution_source_fetch_mode >/dev/null 2>&1; then
        fail "self-test selected a fetch mode for an invalid Ubuntu snapshot"
    fi

    selector="$(distribution_source_selector \
        gst-plugins-good1.0 1.24.2-1ubuntu1.4)"
    [ "$selector" = "gst-plugins-good1.0=1.24.2-1ubuntu1.4" ] \
        || fail "self-test produced a wrong exact distribution source selector"
    for invalid in \
        "-oDir::Etc::sourcelist=/tmp/unsafe" \
        "gst-plugins-good1.0/../../unsafe" \
        $'gst-plugins-good1.0\nunsafe'; do
        if distribution_source_selector "$invalid" 1.24.2-1ubuntu1.4 \
                >/dev/null 2>&1; then
            fail "self-test accepted an unsafe distribution source package argument"
        fi
    done
    for invalid in \
        "" "-1ubuntu1" "1.24.2/../../unsafe" \
        $'1.24.2\n-oDir::Etc::sourcelist=/tmp/unsafe'; do
        if distribution_source_selector gst-plugins-good1.0 "$invalid" \
                >/dev/null 2>&1; then
            fail "self-test accepted an unsafe distribution source version argument"
        fi
    done

    snapshot_root="$tmp/ubuntu-snapshot-apt"
    mkdir -p "$snapshot_root"
    configure_ubuntu_snapshot_apt_root "$snapshot_root" "$snapshot_id"
    snapshot_source_list="$snapshot_root/etc/apt/sources.list.d/dinox-ubuntu-snapshot.sources"
    actual_snapshot_source_list="$(cat "$snapshot_source_list")"
    [ "$actual_snapshot_source_list" = "$(printf \
        'Types: deb-src\nURIs: https://snapshot.ubuntu.com/ubuntu/%s\nSuites: noble noble-updates noble-backports noble-security\nComponents: main universe restricted multiverse\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
        "$snapshot_id")" ] \
        || fail "self-test Ubuntu snapshot deb822 source configuration mismatch"
    expected_snapshot_apt_args=(
        -o "Dir::Etc::main=/dev/null"
        -o "Dir::Etc::parts=-"
        -o "Dir::Etc::sourcelist=$snapshot_source_list"
        -o "Dir::Etc::sourceparts=-"
        -o "Dir::State=$snapshot_root/var/lib/apt"
        -o "Dir::State::Lists=$snapshot_root/var/lib/apt/lists"
        -o "Dir::State::status=$snapshot_root/var/lib/dpkg/status"
        -o "Dir::Cache=$snapshot_root/var/cache/apt"
        -o "Dir::Cache::archives=$snapshot_root/var/cache/apt/archives"
        -o "Dir::Cache::pkgcache=$snapshot_root/var/cache/apt/pkgcache.bin"
        -o "Dir::Cache::srcpkgcache=$snapshot_root/var/cache/apt/srcpkgcache.bin"
        -o "Dir::Log=$snapshot_root/var/log/apt"
        -o "APT::Get::List-Cleanup=0"
        -o "APT::Update::Error-Mode=any"
        -o "Acquire::Retries=3"
        -o "Acquire::http::Timeout=30"
        -o "Acquire::https::Timeout=30"
        -o "Acquire::Check-Valid-Until=false"
    )
    [ "${#UBUNTU_SNAPSHOT_APT_ARGS[@]}" -eq "${#expected_snapshot_apt_args[@]}" ] \
        || fail "self-test isolated Ubuntu snapshot APT argument count mismatch"
    for index in "${!expected_snapshot_apt_args[@]}"; do
        [ "${UBUNTU_SNAPSHOT_APT_ARGS[$index]}" = "${expected_snapshot_apt_args[$index]}" ] \
            || fail "self-test isolated Ubuntu snapshot APT argument mismatch at index $index"
    done
    if (configure_ubuntu_snapshot_apt_root \
            "relative/snapshot-root" "$snapshot_id") >/dev/null 2>&1; then
        fail "self-test accepted a relative Ubuntu snapshot APT root"
    fi
    self_test_ubuntu_snapshot_apt "$tmp" "$snapshot_id"

    if [ -e "$host_alias" ] && dpkg-query -W "$host_owner" >/dev/null 2>&1; then
        owner="$(package_owner_for_path "$host_alias")" \
            || fail "self-test did not resolve the installed usrmerge libreadline t64 owner"
        [ "$owner" = "$host_owner" ] \
            || fail "installed libreadline t64 owner mismatch: $owner"

        mkdir -p "$tmp/appdir/usr/lib"
        cp -L "$host_alias" "$tmp/appdir/usr/lib/libreadline.so.8"
        # Deb dependency discovery may record the usrmerge /lib alias. The
        # stager must accept it but inventory the canonical /usr path.
        printf 'usr/lib/libreadline.so.8\t%s\n' "$host_alias" > "$tmp/source-map.tsv"
        copy_system_package_licenses "$tmp/appdir" "$tmp/source-map.tsv"
        awk -F '\t' -v owner="$host_owner" \
            '$1 == "usr/lib/libreadline.so.8" && $3 == owner && $6 == "readline" \
                && $2 ~ /^\/usr\// && $8 ~ /^[0-9a-f]{64}$/ \
                && $9 ~ /^[0-9a-f]{64}$/ && $10 == "verbatim-copy" \
                && $11 == "/usr/share/doc/libreadline8t64/copyright" { found = 1 } \
             END { exit(found ? 0 : 1) }' \
            "$tmp/appdir/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv" \
            || fail "self-test inventory lost the libreadline t64 owner or copyright path"
        [ -s "$tmp/appdir/usr/share/licenses/dinox/system-packages/libreadline8t64/copyright" ] \
            || fail "self-test did not stage the libreadline t64 copyright file"
    fi

    if [ -e "$host_lzo_alias" ] \
            && dpkg-query -W "$host_lzo_owner" >/dev/null 2>&1 \
            && dpkg-query -S -- "$host_lzo_alias" >/dev/null 2>&1; then
        host_lzo_canonical="$(canonical_package_source_path "$host_lzo_alias")"
        case "$host_lzo_canonical" in
            /usr/lib/*)
                owner="$(package_owner_for_path "$host_lzo_canonical")" \
                    || fail "self-test did not resolve the real liblzo2 usrmerge alias owner"
                [ "$owner" = "$host_lzo_owner" ] \
                    || fail "real liblzo2 usrmerge owner mismatch: $owner"

                lzo_app="$tmp/lzo-app"
                mkdir -p "$lzo_app/usr/lib"
                cp -L "$host_lzo_alias" "$lzo_app/usr/lib/liblzo2.so.2.0.0"
                printf 'usr/lib/liblzo2.so.2.0.0\t%s\n' "$host_lzo_alias" \
                    > "$tmp/lzo-source-map.tsv"
                copy_system_package_licenses "$lzo_app" "$tmp/lzo-source-map.tsv"
                awk -F '\t' -v canonical="$host_lzo_canonical" -v owner="$host_lzo_owner" '
                    NR == 2 && $1 == "usr/lib/liblzo2.so.2.0.0" \
                        && $2 == canonical && $3 == owner { found = 1 }
                    END { exit(found ? 0 : 1) }
                ' "$lzo_app/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv" \
                    || fail "self-test liblzo2 inventory lost its canonical /usr host path"
                ;;
        esac
    fi

    self_test_target="$tmp/usr/lib/x86_64-linux-gnu/libreadline.so.8.2"
    alias="$tmp/lib/x86_64-linux-gnu/libreadline.so.8.2"
    expected_owner="libreadline8t64:amd64"
    mkdir -p "$(dirname "$self_test_target")" "$(dirname "$alias")"
    printf 'readline t64 fixture\n' > "$self_test_target"
    ln -s "$self_test_target" "$alias"

    run_dpkg_query() {
        if [ "$1" = "-S" ] && [ "$2" = "--" ] && [ "$3" = "$self_test_target" ]; then
            printf 'diversion by libreadline8t64 from: %s\n' "$alias"
            printf 'diversion by libreadline8t64 to: %s.usr-is-merged\n' "$alias"
            if [ "$self_test_query_mode" = "valid" ]; then
                printf '%s: %s\n' "$expected_owner" "$self_test_target"
            fi
            return 0
        fi
        if [ "$1" = "-S" ] && [ "$2" = "--" ] && [ "$3" = "$alias" ]; then
            case "$self_test_query_mode" in
                alias-only)
                    printf '%s: %s\n' "$expected_owner" "$alias"
                    ;;
                alias-wrong-path)
                    printf '%s: %s.unrelated\n' "$expected_owner" "$alias"
                    ;;
            esac
            return 0
        fi
        if [ "$1" = "-W" ] && [ "$3" = "$expected_owner" ]; then
            case "$self_test_query_mode" in
                valid|alias-only) ;;
                *) return 1 ;;
            esac
            case "$2" in
                *'${Version}'*)
                    printf '%s\tlibreadline8t64\tamd64\t8.2-test\treadline\t8.2-test\tinstall ok installed' \
                        "$expected_owner"
                    ;;
                *)
                    printf '%s\tlibreadline8t64\tamd64\tinstall ok installed' "$expected_owner"
                    ;;
            esac
            return 0
        fi
        return 1
    }

    owner="$(package_owner_for_path "$alias")" \
        || fail "self-test did not resolve the usrmerge libreadline t64 owner"
    [ "$owner" = "$expected_owner" ] \
        || fail "self-test lost the libreadline t64 architecture qualifier: $owner"

    self_test_query_mode="alias-only"
    owner="$(package_owner_for_path "$self_test_target" "$tmp/usr" "$tmp")" \
        || fail "self-test did not resolve an exact usrmerge legacy alias owner"
    [ "$owner" = "$expected_owner" ] \
        || fail "self-test usrmerge legacy alias owner mismatch: $owner"

    self_test_query_mode="alias-wrong-path"
    if package_owner_for_path "$self_test_target" "$tmp/usr" "$tmp" >/dev/null 2>&1; then
        fail "self-test accepted a dpkg alias result for a different registered path"
    fi

    different_target="$tmp/usr/lib/x86_64-linux-gnu/different.so.1"
    printf 'different usrmerge target\n' > "$different_target"
    rm -f "$alias"
    ln -s "$different_target" "$alias"
    self_test_query_mode="alias-only"
    if package_owner_for_path "$self_test_target" "$tmp/usr" "$tmp" >/dev/null 2>&1; then
        fail "self-test accepted a usrmerge alias resolving to a different canonical file"
    fi
    rm -f "$alias"
    ln -s "$self_test_target" "$alias"

    [ "$(canonical_package_source_path "$alias")" = "$self_test_target" ] \
        || fail "self-test usrmerge alias did not retain the canonical inventory path"

    self_test_query_mode="diversion-only"
    if package_owner_for_path "$alias" "$tmp/usr" "$tmp" >/dev/null 2>&1; then
        fail "self-test accepted a usrmerge diversion as a package owner"
    fi

    if validate_dpkg_binary_package_owner "$expected_owner" \
            $'libreadline8t64:arm64\tlibreadline8t64\tarm64\tinstall ok installed'; then
        fail "self-test accepted mismatched dpkg package metadata"
    fi

    self_test_query_mode="valid"
    fixture_app="$tmp/fixture-app"
    mkdir -p "$fixture_app/usr/lib"
    cp -L "$alias" "$fixture_app/usr/lib/libreadline.so.8"
    printf 'usr/lib/libreadline.so.8\t%s\n' "$self_test_target" > "$tmp/fixture-map.tsv"
    copy_system_package_licenses "$fixture_app" "$tmp/fixture-map.tsv"
    awk -F '\t' -v owner="$expected_owner" -v host="$self_test_target" \
        'NR == 1 {
            if ($0 != "package_path\thost_source_path\tbinary_package\tbinary_version\tarchitecture\tsource_package\tsource_version\tpackaged_sha256\thost_source_sha256\ttransform\tcopyright_path") exit 1
        }
        NR == 2 && $1 == "usr/lib/libreadline.so.8" && $2 == host \
            && $3 == owner && $4 == "8.2-test" && $5 == "amd64" \
            && $6 == "readline" && $7 == "8.2-test" \
            && $8 ~ /^[0-9a-f]{64}$/ && $9 == $8 \
            && $10 == "verbatim-copy" { found = 1 }
        END { exit(found ? 0 : 1) }' \
        "$fixture_app/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv" \
        || fail "self-test file-level runtime inventory is incomplete"

    project_app="$tmp/project-app"
    project_map="$tmp/project-install-map.txt"
    mkdir -p "$project_app/usr/lib"
    printf 'Meson-installed DinoX library\n' > "$project_app/usr/lib/libdino.so.0.0"
    cp "$project_app/usr/lib/libdino.so.0.0" "$project_app/usr/lib/libdino-copy.so.0.0"
    printf 'usr/lib/libdino.so.0.0\n' > "$project_map"
    printf 'usr/lib/libdino-copy.so.0.0\t%s\n' \
        "$project_app/usr/lib/libdino.so.0.0" > "$tmp/project-source-map.tsv"
    copy_system_package_licenses "$project_app" "$tmp/project-source-map.tsv" "$project_map"
    [ "$(wc -l < "$project_app/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv")" -eq 1 ] \
        || fail "self-test inventoried a Meson-installed DinoX artifact as a Debian file"

    printf 'unlisted AppDir runtime\n' > "$project_app/usr/lib/unlisted.so"
    cp "$project_app/usr/lib/unlisted.so" "$project_app/usr/lib/unlisted-copy.so"
    printf 'usr/lib/unlisted-copy.so\t%s\n' \
        "$project_app/usr/lib/unlisted.so" > "$tmp/unlisted-internal-map.tsv"
    if (copy_system_package_licenses "$project_app" "$tmp/unlisted-internal-map.tsv" "$project_map") \
            >/dev/null 2>&1; then
        fail "self-test accepted an AppDir-internal source absent from the Meson install map"
    fi

    cp -L "$alias" "$fixture_app/usr/lib/libdistribution.so"
    cp -L "$alias" "$fixture_app/usr/lib/libdistribution-copy.so"
    {
        printf 'usr/lib/libdistribution.so\t%s\n' "$self_test_target"
        printf 'usr/lib/libdistribution-copy.so\t%s\n' \
            "$fixture_app/usr/lib/libdistribution.so"
    } > "$tmp/distribution-reuse-map.tsv"
    copy_system_package_licenses "$fixture_app" "$tmp/distribution-reuse-map.tsv" "$project_map"
    [ "$(wc -l < "$fixture_app/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv")" -eq 2 ] \
        || fail "self-test duplicated or lost an already-inventoried distribution dependency"
    ! grep -F $'usr/lib/libdistribution-copy.so\t' \
        "$fixture_app/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv" >/dev/null \
        || fail "self-test duplicated an AppDir-internal distribution dependency row"

    ln -s missing-runtime-target "$fixture_app/usr/lib/broken-runtime.so"
    printf 'usr/lib/broken-runtime.so\t%s\n' "$self_test_target" > "$tmp/broken-map.tsv"
    if (copy_system_package_licenses "$fixture_app" "$tmp/broken-map.tsv") >/dev/null 2>&1; then
        fail "self-test accepted a broken packaged runtime symlink"
    fi
    rm -f "$fixture_app/usr/lib/broken-runtime.so"

    ln -s "$self_test_target" "$fixture_app/usr/lib/escaping-runtime.so"
    printf 'usr/lib/escaping-runtime.so\t%s\n' "$self_test_target" > "$tmp/escaping-map.tsv"
    if (copy_system_package_licenses "$fixture_app" "$tmp/escaping-map.tsv") >/dev/null 2>&1; then
        fail "self-test accepted a packaged runtime symlink escaping the package root"
    fi
    rm -f "$fixture_app/usr/lib/escaping-runtime.so"

    printf 'post-copy relocation fixture\n' >> "$fixture_app/usr/lib/libreadline.so.8"
    copy_system_package_licenses "$fixture_app" "$tmp/fixture-map.tsv"
    awk -F '\t' '
        NR == 2 && $8 ~ /^[0-9a-f]{64}$/ && $9 ~ /^[0-9a-f]{64}$/ \
            && $8 != $9 && $10 == "post-copy-modified" { found = 1 }
        END { exit(found ? 0 : 1) }' \
        "$fixture_app/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv" \
        || fail "self-test lost provenance for a post-copy-modified runtime file"

    self_test_query_mode="diversion-only"
    if (copy_system_package_licenses "$fixture_app" "$tmp/fixture-map.tsv" "$project_map") >/dev/null 2>&1; then
        fail "self-test accepted an unowned copied runtime file"
    fi
    self_test_query_mode="valid"

    fixture_source="$tmp/source-fixture"
    mkdir -p "$tmp/fixture-1.0/debian/source" "$fixture_source"
    printf '3.0 (native)\n' > "$tmp/fixture-1.0/debian/source/format"
    printf 'fixture (1.0) unstable; urgency=medium\n\n  * Compliance fixture.\n\n -- DinoX Team <contact@dinox.im>  Wed, 22 Jul 2026 00:00:00 +0000\n' \
        > "$tmp/fixture-1.0/debian/changelog"
    printf 'Source: fixture\nSection: misc\nPriority: optional\nMaintainer: DinoX Team <contact@dinox.im>\nStandards-Version: 4.6.2\n\nPackage: fixture\nArchitecture: any\nDescription: compliance fixture\n' \
        > "$tmp/fixture-1.0/debian/control"
    (cd "$tmp" && dpkg-source -b fixture-1.0 >/dev/null)
    find "$tmp" -maxdepth 1 -type f \
        \( -name 'fixture_1.0.dsc' -o -name 'fixture_1.0.tar.*' \) \
        -exec cp -a '{}' "$fixture_source/" ';'
    write_distribution_source_metadata \
        "$fixture_source" fixture 1.0 fixture-bin:amd64
    validate_distribution_source_tree "$fixture_source" fixture 1.0
    printf 'corrupt\n' >> "$(find "$fixture_source" -maxdepth 1 -type f -name '*.tar.*' -print -quit)"
    if (validate_distribution_source_tree "$fixture_source" fixture 1.0) >/dev/null 2>&1; then
        fail "self-test accepted a corrupted Debian source payload"
    fi

    debian_fixture="$tmp/debian-copyright"
    copy_project_license "$debian_fixture" deb
    mkdir -p \
        "$debian_fixture/usr/share/licenses/dinox/custom-dependencies/example/files" \
        "$debian_fixture/usr/share/licenses/dinox/system-packages/example" \
        "$debian_fixture/usr/share/licenses/dinox/google-libwebrtc"
    printf 'source_url=https://example.invalid/example\n' \
        > "$debian_fixture/usr/share/licenses/dinox/custom-dependencies/example/METADATA"
    printf 'custom-license-marker\n' \
        > "$debian_fixture/usr/share/licenses/dinox/custom-dependencies/example/files/LICENSE"
    printf 'system-copyright-marker\n' \
        > "$debian_fixture/usr/share/licenses/dinox/system-packages/example/copyright"
    printf 'google-license-marker\n' \
        > "$debian_fixture/usr/share/licenses/dinox/google-libwebrtc/LICENSE.md"
    printf 'third-party-origin-marker\n' \
        > "$debian_fixture/usr/share/licenses/dinox/THIRD_PARTY_NOTICES.md"
    printf 'package_path\thost_source_path\n' \
        > "$debian_fixture/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv"
    write_debian_copyright "$debian_fixture" deb
    for marker in third-party-origin-marker custom-license-marker \
            system-copyright-marker google-license-marker; do
        grep -Fx "$marker" "$debian_fixture/usr/share/doc/dinox/copyright" >/dev/null \
            || fail "self-test Debian copyright omitted $marker"
    done
    [ -f "$debian_fixture/usr/share/doc/dinox/copyright" ] \
        && [ ! -L "$debian_fixture/usr/share/doc/dinox/copyright" ] \
        || fail "self-test Debian copyright is not a regular file"

    echo "Self-test OK: usrmerge aliases, project/distribution provenance, symlink boundaries, Debian copyright and exact sources"
}

copy_system_package_licenses() {
    local root="$1"
    local source_map="$2"
    local project_map="${3:-}"
    local destination="$root/usr/share/licenses/dinox/system-packages"
    local inventory="$root/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv"
    local sorted_map normalized_map map_extra
    local package_relative source_path canonical_source target canonical_target source_relative
    local owner owner_package metadata binary_package package_name architecture status inventory_binary_package
    local binary_version source_package source_version copyright_path packaged_sha source_sha transform extra

    [ -n "$source_map" ] || return 0
    [ -s "$source_map" ] || fail "license source map is empty: $source_map"
    command -v dpkg-query >/dev/null 2>&1 || fail "dpkg-query is required to stage copied system licenses"
    if [ -n "$project_map" ]; then
        [ -s "$project_map" ] || fail "project install map is empty: $project_map"
        awk '
            $0 == "" || $0 == "." || $0 == ".." || $0 ~ /^\// \
                || $0 ~ /^\.\.\// || $0 ~ /\/\.\.\// || $0 ~ /\/\.\.$/ \
                || index($0, "\t") || seen[$0]++ { exit 1 }
        ' "$project_map" || fail "project install map contains unsafe or duplicate paths"
    fi

    install -d -m 0755 "$destination"
    printf 'package_path\thost_source_path\tbinary_package\tbinary_version\tarchitecture\tsource_package\tsource_version\tpackaged_sha256\thost_source_sha256\ttransform\tcopyright_path\n' > "$inventory"
    sorted_map="$(mktemp)"
    normalized_map="$(mktemp)"
    while IFS=$'\t' read -r package_relative source_path map_extra; do
        [ -n "$package_relative" ] && [ -n "$source_path" ] && [ -z "${map_extra:-}" ] \
            || { rm -f "$sorted_map" "$normalized_map"; fail "invalid license source-map row"; }
        canonical_source="$(canonical_package_source_path "$source_path" || true)"
        [ -n "$canonical_source" ] \
            || { rm -f "$sorted_map" "$normalized_map"; fail "recorded package source is not canonicalizable: $source_path"; }
        printf '%s\t%s\n' "$package_relative" "$canonical_source" >> "$normalized_map"
    done < "$source_map"
    sort -u "$normalized_map" > "$sorted_map"
    rm -f "$normalized_map"

    if ! awk -F '\t' '
        NF != 2 || $1 == "" || $2 == "" { exit 1 }
        seen[$1] && seen[$1] != $2 { exit 1 }
        { seen[$1] = $2 }
    ' "$sorted_map"; then
        rm -f "$sorted_map"
        fail "license source map contains invalid or conflicting rows"
    fi

    while IFS=$'\t' read -r package_relative source_path; do
        [ -n "$package_relative" ] || continue
        [ -n "$source_path" ] || fail "invalid license source-map row for $package_relative"
        case "$package_relative" in
            /*|../*|*/../*|*/..|.|..) fail "unsafe package-relative source-map path: $package_relative" ;;
        esac
        target="$root/$package_relative"
        if [ -L "$target" ] && [ ! -e "$target" ]; then
            fail "packaged runtime source-map target is a broken symlink: $package_relative"
        fi
        [ -e "$target" ] || continue
        [ -e "$source_path" ] || fail "recorded package source disappeared: $source_path"

        canonical_source="$source_path"
        canonical_target="$(canonical_package_source_path "$target" || true)"
        [ -n "$canonical_target" ] \
            || fail "packaged runtime file is not canonicalizable: $package_relative"
        case "$canonical_target" in
            "$root"/*) ;;
            *) fail "packaged runtime source-map target escapes package root: $package_relative" ;;
        esac

        case "$canonical_source" in
            "$root"/*)
                source_relative="${canonical_source#"$root"/}"
                if [ -n "$project_map" ] && grep -Fx -- "$source_relative" "$project_map" >/dev/null; then
                    # Meson installed this package artifact before any external
                    # runtime was copied. Project and pinned Google-runtime
                    # license trees cover it; it has no Debian package owner.
                    continue
                fi
                if awk -F '\t' -v target="$source_relative" -v package_root="$root/" '
                        $1 == target && index($2, package_root) != 1 { found = 1 }
                        END { exit(found ? 0 : 1) }
                    ' "$sorted_map"; then
                    # A distribution file already copied and inventoried may
                    # later be returned by ldd as an AppDir-internal dependency.
                    # The external row remains authoritative; do not duplicate it.
                    continue
                fi
                fail "package-internal runtime source is neither Meson-installed nor distribution-inventoried: $source_relative"
                ;;
        esac

        owner="$(package_owner_for_path "$canonical_source" || true)"
        [ -n "$owner" ] || fail "no Debian package owns copied runtime file: $canonical_source"
        owner_package="${owner%%:*}"
        copyright_path="/usr/share/doc/$owner_package/copyright"
        [ -s "$copyright_path" ] || fail "copyright file missing for copied runtime package $owner"

        metadata="$(run_dpkg_query -W \
            -f='${binary:Package}\t${Package}\t${Architecture}\t${Version}\t${source:Package}\t${source:Version}\t${Status}' \
            "$owner" 2>/dev/null || true)"
        IFS=$'\t' read -r binary_package package_name architecture binary_version \
            source_package source_version status extra <<< "$metadata"
        [ -z "${extra:-}" ] || fail "ambiguous package metadata for copied runtime package $owner"
        [ "$binary_package" = "$owner" ] \
            || fail "binary package metadata mismatch for copied runtime package $owner"
        [ "$status" = "install ok installed" ] \
            || fail "copied runtime package is not installed: $owner"
        [ -n "$binary_version" ] || fail "version unavailable for copied runtime package $owner"
        [ -n "$source_package" ] || source_package="$owner_package"
        [ -n "$source_version" ] || source_version="$binary_version"
        [[ "$source_package" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] \
            || fail "invalid source package metadata for copied runtime package $owner"
        [ -n "$architecture" ] \
            || fail "architecture unavailable for copied runtime package $owner"
        inventory_binary_package="$package_name:$architecture"

        packaged_sha="$(sha256sum "$target" | awk '{ print $1 }')"
        source_sha="$(sha256sum "$canonical_source" | awk '{ print $1 }')"
        if [ "$packaged_sha" = "$source_sha" ]; then
            transform="verbatim-copy"
        else
            # AppImage relocation may modify an ELF after it was copied (for
            # example with patchelf). Preserve both hashes instead of losing
            # the owning binary/source-package provenance for that file.
            transform="post-copy-modified"
        fi

        install -d -m 0755 "$destination/$owner_package"
        install -m 0644 "$copyright_path" "$destination/$owner_package/copyright"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$package_relative" "$canonical_source" "$inventory_binary_package" "$binary_version" \
            "$architecture" "$source_package" "$source_version" "$packaged_sha" "$source_sha" \
            "$transform" "$copyright_path" >> "$inventory"
    done < "$sorted_map"
    rm -f "$sorted_map"

    {
        head -1 "$inventory"
        tail -n +2 "$inventory" | sort -u
    } > "$inventory.sorted"
    mv "$inventory.sorted" "$inventory"
}

write_notice_index() {
    local root="$1"
    local output="$root/usr/share/licenses/dinox/THIRD_PARTY_NOTICES.md"
    local inventory="$root/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv"
    local metadata
    local component version source_url checksum_algorithm checksum

    {
        printf '# DinoX bundled third-party notices\n\n'
        printf 'This index is generated from the exact package-builder inputs. '
        printf 'The corresponding license and copyright texts are stored below this directory.\n\n'
        printf '## Custom-built components\n\n'
        for metadata in "$root"/usr/share/licenses/dinox/custom-dependencies/*/METADATA; do
            [ -s "$metadata" ] || continue
            component="$(sed -n 's/^component=//p' "$metadata")"
            version="$(sed -n 's/^version=//p' "$metadata")"
            source_url="$(sed -n 's/^source_url=//p' "$metadata")"
            checksum_algorithm="$(sed -n 's/^checksum_algorithm=//p' "$metadata")"
            checksum="$(sed -n 's/^checksum=//p' "$metadata")"
            printf -- '- %s %s — %s — %s `%s`\n' \
                "$component" "$version" "$source_url" "$checksum_algorithm" "$checksum"
        done
        printf '\n## Distribution-owned files copied into this package\n\n'
        if [ -s "$inventory" ] && [ "$(wc -l < "$inventory")" -gt 1 ]; then
            tail -n +2 "$inventory" | while IFS=$'\t' read -r package_path host_path \
                    package version architecture source_package source_version packaged_sha \
                    host_sha transform copyright_path; do
                printf -- '- `%s`: %s %s (%s; source: %s %s; packaged SHA256 `%s`; host SHA256 `%s`; transform: %s; host: `%s`; copyright: `%s`)\n' \
                    "$package_path" "$package" "$version" "$architecture" \
                    "$source_package" "$source_version" "$packaged_sha" "$host_sha" \
                    "$transform" "$host_path" "$copyright_path"
            done
        else
            printf 'No distribution-owned runtime files are privately copied by this package.\n'
        fi
        printf '\n## Google/libwebrtc\n\n'
        printf 'See `google-libwebrtc/` for the WebRTC, transitive third-party, patent, '
        printf 'FFmpeg and libva notices tied to the pinned runtime artifact.\n'
        if [ -d "$root/usr/share/licenses/dinox/corresponding-sources" ]; then
            printf '\n## AppImage corresponding source\n\n'
            printf 'The exact verified source archives for the GPL recorder FFmpeg/x264 '
            printf 'and every copied Ubuntu distribution runtime file are stored in '
            printf '`corresponding-sources/`.\n'
        fi
    } > "$output"
}

append_debian_copyright_tree() {
    local output="$1"
    local license_root="$2"
    local tree="$3"
    local path relative

    [ -d "$tree" ] || fail "Debian copyright material directory missing: $tree"
    while IFS= read -r -d '' path; do
        relative="${path#"$license_root"/}"
        {
            printf '\n\n===== BEGIN VERBATIM FILE: /usr/share/licenses/dinox/%s =====\n\n' "$relative"
            cat -- "$path"
            printf '\n===== END VERBATIM FILE: /usr/share/licenses/dinox/%s =====\n' "$relative"
        } >> "$output"
    done < <(
        find "$tree" \
            \( -path '*/sources' -o -path '*/sources/*' \) -prune -o \
            -type f -size +0c -print0 | sort -z
    )
}

write_debian_copyright() {
    local root="$1"
    local mode="$2"
    local license_root="$root/usr/share/licenses/dinox"
    local doc_root="$root/usr/share/doc/dinox"
    local output="$doc_root/copyright"
    local temporary

    [ "$mode" = "deb" ] || return 0
    [ -s "$license_root/THIRD_PARTY_NOTICES.md" ] \
        || fail "Debian third-party provenance notice is missing"
    [ -s "$license_root/SYSTEM_COMPONENTS.tsv" ] \
        || fail "Debian distribution-component inventory is missing"

    install -d -m 0755 "$doc_root"
    temporary="$(mktemp "$doc_root/.copyright.XXXXXX")"
    {
        printf 'DinoX Debian copyright and bundled-license record\n'
        printf '==================================================\n\n'
        printf 'Upstream-Name: DinoX\n'
        printf 'Source: https://git.dinox.im/dinoxim/dinox\n'
        printf 'Upstream-Contact: DinoX Team <contact@dinox.im>\n\n'
        printf 'This file contains verbatim copies of the distribution licenses, '
        printf 'copyright notices and additional permissions for DinoX and every '
        printf 'third-party component privately bundled in this binary package.\n'
        printf 'Source origins, exact versions and checksums are recorded below.\n\n'
        cat "$license_root/THIRD_PARTY_NOTICES.md"
        printf '\n\n===== DISTRIBUTION-OWNED RUNTIME INVENTORY =====\n\n'
        cat "$license_root/SYSTEM_COMPONENTS.tsv"
    } > "$temporary"

    append_debian_copyright_tree "$temporary" "$license_root" "$license_root/dinox"
    append_debian_copyright_tree "$temporary" "$license_root" "$license_root/custom-dependencies"
    append_debian_copyright_tree "$temporary" "$license_root" "$license_root/system-packages"
    append_debian_copyright_tree "$temporary" "$license_root" "$license_root/google-libwebrtc"

    install -m 0644 "$temporary" "$output"
    rm -f "$temporary"
    install -m 0644 "$PROJECT_ROOT/AUTHORS" "$doc_root/AUTHORS"
    [ -f "$output" ] && [ ! -L "$output" ] && [ -s "$output" ] \
        || fail "Debian copyright must be a non-empty regular file"
}

trap cleanup_ubuntu_snapshot_apt_root EXIT

mode=""
root=""
source_map=""
project_map=""

if [ "$#" -eq 1 ] && [ "$1" = "--self-test" ]; then
    run_self_test
    exit 0
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode)
            mode="${2:-}"
            shift 2
            ;;
        --root)
            root="${2:-}"
            shift 2
            ;;
        --source-map)
            source_map="${2:-}"
            shift 2
            ;;
        --project-map)
            project_map="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

case "$mode" in
    deb|appimage) ;;
    *) fail "--mode must be deb or appimage" ;;
esac
[ -n "$root" ] || fail "--root is required"
[ -d "$root" ] || fail "package root does not exist: $root"
root="$(abs_path "$root")"
if [ -n "$source_map" ]; then
    source_map="$(abs_path "$source_map")"
fi
if [ -n "$project_map" ]; then
    project_map="$(abs_path "$project_map")"
fi
if [ "$mode" = "appimage" ]; then
    [ -n "$project_map" ] && [ -s "$project_map" ] \
        || fail "AppImage --project-map is required and must be non-empty"
elif [ -n "$project_map" ]; then
    fail "--project-map is only valid for appimage mode"
fi

copy_ibus_compat_material() {
    local root="$1"
    local prefix="${DINOX_IBUS_COMPAT_PREFIX:-}"
    local license_destination="$root/usr/share/licenses/dinox/custom-dependencies/ibus-compat"
    local source_destination="$root/usr/share/licenses/dinox/corresponding-sources/ibus-compat"

    [ -n "$prefix" ] || return 0
    bash "$PROJECT_ROOT/scripts/prepare-ibus-compat.sh" --check "$prefix" \
        || fail "private IBus license/source input is incomplete"
    install -d -m 0755 "$license_destination" "$source_destination"
    cp -a "$prefix/share/dinox/custom-dependency-licenses/ibus-compat/." "$license_destination/"
    cp -a "$prefix/share/dinox/corresponding-sources/ibus-compat/." "$source_destination/"
    install -m 0644 "$PROJECT_ROOT/scripts/prepare-ibus-compat.sh" \
        "$source_destination/prepare-ibus-compat.sh"
}

copy_project_license "$root" "$mode"
copy_custom_dependency_licenses "$root" "$mode"
copy_ibus_compat_material "$root"
if [ "$mode" = appimage ]; then
    canberra_prefix="${DINOX_CANBERRA_RUNTIME_PREFIX:-}"
    [ -n "$canberra_prefix" ] || fail "private libcanberra source prefix is required"
    bash "$PROJECT_ROOT/scripts/prepare-canberra-runtime.sh" --check "$canberra_prefix" \
        || fail "private libcanberra license/source input is incomplete"
    mkdir -p "$root/usr/share/licenses/dinox/custom-dependencies/canberra-runtime" \
        "$root/usr/share/licenses/dinox/corresponding-sources/canberra-runtime"
    cp -a "$canberra_prefix/share/dinox/custom-dependency-licenses/canberra-runtime/." \
        "$root/usr/share/licenses/dinox/custom-dependencies/canberra-runtime/"
    cp -a "$canberra_prefix/share/dinox/corresponding-sources/canberra-runtime/." \
        "$root/usr/share/licenses/dinox/corresponding-sources/canberra-runtime/"
fi
copy_recorder_corresponding_sources "$root" "$mode"
copy_system_package_licenses "$root" "$source_map" "$project_map"
copy_distribution_corresponding_sources "$root" "$mode"
write_notice_index "$root"
write_debian_copyright "$root" "$mode"

for required in \
    "$root/usr/share/licenses/dinox/dinox/LICENSE" \
    "$root/usr/share/licenses/dinox/THIRD_PARTY_NOTICES.md" \
    "$root/usr/share/licenses/dinox/google-libwebrtc/LICENSE" \
    "$root/usr/share/licenses/dinox/google-libwebrtc/LICENSE.md" \
    "$root/usr/share/licenses/dinox/google-libwebrtc/PATENTS" \
    "$root/usr/share/licenses/dinox/google-libwebrtc/FFMPEG-LICENSE" \
    "$root/usr/share/licenses/dinox/google-libwebrtc/LIBVA-LICENSE"; do
    [ -s "$required" ] || fail "required packaged license file missing: $required"
done

if [ "$mode" = "deb" ]; then
    [ -s "$root/usr/share/doc/dinox/copyright" ] \
        || fail "Debian copyright file missing"
fi

if [ "$mode" = "appimage" ]; then
    for required in \
        "$root/usr/share/licenses/dinox/custom-dependencies/recorder-ffmpeg/METADATA" \
        "$root/usr/share/licenses/dinox/custom-dependencies/recorder-x264/METADATA" \
        "$root/usr/share/licenses/dinox/corresponding-sources/recorder-ffmpeg/ffmpeg-$FFMPEG_RECORDER_VERSION.tar.xz" \
        "$root/usr/share/licenses/dinox/corresponding-sources/recorder-x264/x264-$X264_RECORDER_COMMIT.tar.gz" \
        "$root/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv" \
        "$root/usr/share/licenses/dinox/corresponding-sources/distribution/gnupg2/METADATA" \
        "$root/usr/share/licenses/dinox/corresponding-sources/distribution/gnupg2/SHA256SUMS"; do
        [ -s "$required" ] || fail "required AppImage compliance file missing: $required"
    done
fi

echo "Package license material staged: $root/usr/share/licenses/dinox"
