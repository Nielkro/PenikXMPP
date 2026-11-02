#!/bin/bash
set -euo pipefail

MANIFEST="${DINOX_PACKAGE_BUILDER_MANIFEST:-/usr/local/share/dinox/package-builder-manifest.env}"
MAX_AGE_DAYS="${DINOX_PACKAGE_BUILDER_MAX_AGE_DAYS:-45}"
APT_ROOT="${DINOX_PACKAGE_BUILDER_APT_ROOT:-/etc/apt}"
EXPECTED_BASE_IMAGE="catthehacker/ubuntu:act-24.04@sha256:3220992391c1182a0cfe4c64453511772c54f4c39e960d26a5e327960675982e"
IMAGE_BASE_IMAGE="${DINOX_PACKAGE_BUILDER_BASE_IMAGE:-}"
IMAGE_UBUNTU_APT_SNAPSHOT="${DINOX_UBUNTU_APT_SNAPSHOT:-}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

sha256_file() {
    local path="$1"
    [ -f "$path" ] || fail "required file missing: $path"
    sha256sum "$path" | awk '{print $1}'
}

require_manifest_value() {
    local name="$1"
    local expected="$2"
    local actual="${!name:-}"

    if [ -z "$actual" ]; then
        fail "package builder manifest misses $name"
    fi
    if [ "$actual" != "$expected" ]; then
        fail "package builder image is stale for $name: $actual != $expected"
    fi
    echo "OK $name"
}

verify_apt_sources() {
    local ubuntu_sources="$APT_ROOT/sources.list.d/ubuntu.sources"
    local -a source_files=()

    [ -d "$APT_ROOT" ] || fail "APT configuration root is missing: $APT_ROOT"
    while IFS= read -r -d '' source_file; do
        source_files+=("$source_file")
    done < <(
        find "$APT_ROOT" -maxdepth 2 -type f \
            \( -name '*.list' -o -name '*.sources' \) \
            -print0
    )

    [ "${#source_files[@]}" -eq 1 ] \
        || fail "package builder must have exactly one APT source file, found ${#source_files[@]}: ${source_files[*]:-none}"
    [ "${source_files[0]}" = "$ubuntu_sources" ] \
        || fail "foreign APT source file is active: ${source_files[0]}"
    [ "$(grep -Ec '^(Types|URIs|Suites|Components|Signed-By|Snapshot):' "$ubuntu_sources")" -eq 12 ] \
        || fail "package builder ubuntu.sources contains additional or incomplete repository stanzas"
    [ "$(grep -Fxc 'Types: deb deb-src' "$ubuntu_sources")" -eq 2 ] \
        || fail "package builder Ubuntu sources do not enable exactly two deb/deb-src stanzas"
    [ "$(grep -Fxc 'URIs: http://archive.ubuntu.com/ubuntu/' "$ubuntu_sources")" -eq 1 ] \
        || fail "package builder archive source is not the official Ubuntu archive"
    [ "$(grep -Fxc 'URIs: http://security.ubuntu.com/ubuntu/' "$ubuntu_sources")" -eq 1 ] \
        || fail "package builder security source is not the official Ubuntu archive"
    [ "$(grep -Fxc 'Suites: noble noble-updates noble-backports' "$ubuntu_sources")" -eq 1 ] \
        || fail "package builder Ubuntu archive suites are unexpected"
    [ "$(grep -Fxc 'Suites: noble-security' "$ubuntu_sources")" -eq 1 ] \
        || fail "package builder Ubuntu security suite is unexpected"
    [ "$(grep -Fxc 'Components: main universe restricted multiverse' "$ubuntu_sources")" -eq 2 ] \
        || fail "package builder Ubuntu components are unexpected"
    [ "$(grep -Fxc 'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' "$ubuntu_sources")" -eq 2 ] \
        || fail "package builder Ubuntu sources do not use only the Ubuntu archive keyring"
    ! grep -Eq '^Enabled:[[:space:]]*(no|false|0)([[:space:]]|$)' "$ubuntu_sources" \
        || fail "package builder Ubuntu sources are disabled"
    [ "$(grep -Fxc "Snapshot: $DINOX_UBUNTU_APT_SNAPSHOT" "$ubuntu_sources")" -eq 2 ] \
        || fail "package builder Ubuntu sources are not pinned to $DINOX_UBUNTU_APT_SNAPSHOT"
}

[ -f "$MANIFEST" ] || fail "package builder manifest not found: $MANIFEST"
# shellcheck disable=SC1090
. "$MANIFEST"

[ "${DINOX_PACKAGE_BUILDER_SCHEMA:-}" = "1" ] || fail "unsupported package builder manifest schema: ${DINOX_PACKAGE_BUILDER_SCHEMA:-missing}"
dockerfile_base_image="$(awk '$1 == "FROM" { print $2; exit }' \
    ci/images/linux-package-builder-dinox/Dockerfile)"
[ "$dockerfile_base_image" = "$EXPECTED_BASE_IMAGE" ] \
    || fail "package builder Dockerfile has an unexpected base image: ${dockerfile_base_image:-missing}"
[ "${DINOX_PACKAGE_BUILDER_BASE_IMAGE:-}" = "$EXPECTED_BASE_IMAGE" ] \
    || fail "package builder manifest has an unexpected base image: ${DINOX_PACKAGE_BUILDER_BASE_IMAGE:-missing}"
[ "$IMAGE_BASE_IMAGE" = "$DINOX_PACKAGE_BUILDER_BASE_IMAGE" ] \
    || fail "package builder environment and manifest use different base images"
echo "OK package builder base image: $DINOX_PACKAGE_BUILDER_BASE_IMAGE"
[[ "${DINOX_UBUNTU_APT_SNAPSHOT:-}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] \
    || fail "package builder manifest has an invalid Ubuntu APT snapshot"
[ "$IMAGE_UBUNTU_APT_SNAPSHOT" = "$DINOX_UBUNTU_APT_SNAPSHOT" ] \
    || fail "package builder environment and manifest use different Ubuntu APT snapshots"
verify_apt_sources
echo "OK Ubuntu APT snapshot: $DINOX_UBUNTU_APT_SNAPSHOT"

if [ "$MAX_AGE_DAYS" != "0" ]; then
    [ -n "${DINOX_PACKAGE_BUILDER_BUILT_AT:-}" ] || fail "package builder manifest misses build timestamp"
    built_epoch="$(date -u -d "$DINOX_PACKAGE_BUILDER_BUILT_AT" +%s 2>/dev/null || true)"
    [ -n "$built_epoch" ] || fail "invalid package builder build timestamp: $DINOX_PACKAGE_BUILDER_BUILT_AT"
    now_epoch="$(date -u +%s)"
    max_age_seconds=$((MAX_AGE_DAYS * 24 * 60 * 60))
    age_seconds=$((now_epoch - built_epoch))
    if [ "$age_seconds" -gt "$max_age_seconds" ]; then
        fail "package builder image is older than ${MAX_AGE_DAYS} days: $DINOX_PACKAGE_BUILDER_BUILT_AT"
    fi
    echo "OK package builder age: $DINOX_PACKAGE_BUILDER_BUILT_AT"
fi

require_manifest_value DINOX_CI_BUILD_DEPS_SHA256 "$(sha256_file scripts/ci-build-deps.sh)"
require_manifest_value DINOX_VERIFY_CI_DEPS_SHA256 "$(sha256_file scripts/verify-ci-deps.sh)"
require_manifest_value DINOX_VERIFY_PACKAGE_BUILDER_SHA256 "$(sha256_file scripts/verify-package-builder-image.sh)"
require_manifest_value DINOX_LINUX_PACKAGE_BUILDER_DOCKERFILE_SHA256 "$(sha256_file ci/images/linux-package-builder-dinox/Dockerfile)"

pkg-config --atleast-version=1.19 libunbound \
    || fail "package builder needs libunbound-dev >= 1.19 for DNSSEC/DANE"
echo "OK libunbound $(pkg-config --modversion libunbound)"

echo "Linux package builder image manifest verified."
