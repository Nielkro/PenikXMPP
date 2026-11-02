#!/usr/bin/env bash
set -euo pipefail

LIBOMEMO_C_README_SHA256="83adeac2f4760208e75160502dce8931a9c918151fb4518ce6e3f011abed2057"
LIBOMEMO_C_ADDITIONAL_PERMISSION='Additional Permissions For Submission to Apple App Store: Provided that you are otherwise in compliance with the GPLv3 for each covered work you convey (including without limitation making the Corresponding Source available in compliance with Section 6 of the GPLv3), Open Whisper Systems and Dino Team also grant you the additional permission to convey through the Apple App Store non-source executable versions of the Program as incorporated into each applicable covered work as Executable Versions only under the Mozilla Public License version 2.0 (https://www.mozilla.org/en-US/MPL/2.0/).'

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_libomemo_additional_permission() {
    local readme="$1"
    local expected_sha256="${2:-$LIBOMEMO_C_README_SHA256}"

    [[ -s "$readme" ]] || fail "libomemo-c additional-permission README is missing: $readme"
    printf '%s  %s\n' "$expected_sha256" "$readme" | sha256sum -c - >/dev/null \
        || fail "libomemo-c additional-permission README checksum mismatch"
    grep -Fx "$LIBOMEMO_C_ADDITIONAL_PERMISSION" "$readme" >/dev/null \
        || fail "libomemo-c App Store additional permission is missing from README.md"
}

usage() {
    cat <<'EOF'
Usage:
  stage-flatpak-module-licenses.sh COMPONENT SOURCE_ROOT
  stage-flatpak-module-licenses.sh --self-test
  stage-flatpak-module-licenses.sh --help

Copies non-empty license, copyright and notice files from a Flatpak module's
source tree into /app/share/licenses/dinox/third-party/COMPONENT while keeping
their relative paths. DINOX_FLATPAK_APP_PREFIX may override /app for tests.
EOF
}

run_self_test() {
    local tmp source prefix permission_fixture permission_hash
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    source="$tmp/source"
    prefix="$tmp/app"
    mkdir -p "$source/vendor/example" "$prefix"
    printf '%s\n' 'main license text' > "$source/LICENSE"
    printf '%s\n' 'vendored notice text' > "$source/vendor/example/NOTICE.txt"
    : > "$source/COPYING.empty"

    DINOX_FLATPAK_APP_PREFIX="$prefix" \
        "$0" test-component "$source" >/dev/null
    [[ -s "$prefix/share/licenses/dinox/third-party/test-component/LICENSE" ]] \
        || fail "self-test did not stage the root license"
    [[ -s "$prefix/share/licenses/dinox/third-party/test-component/vendor/example/NOTICE.txt" ]] \
        || fail "self-test did not preserve a vendored notice path"
    [[ ! -e "$prefix/share/licenses/dinox/third-party/test-component/COPYING.empty" ]] \
        || fail "self-test staged an empty license file"

    if DINOX_FLATPAK_APP_PREFIX="$prefix" \
            "$0" '../invalid' "$source" >/dev/null 2>&1; then
        fail "self-test accepted an unsafe component name"
    fi
    mkdir -p "$tmp/no-license"
    if DINOX_FLATPAK_APP_PREFIX="$prefix" \
            "$0" no-license "$tmp/no-license" >/dev/null 2>&1; then
        fail "self-test accepted a source tree without license material"
    fi

    permission_fixture="$tmp/libomemo-README.md"
    printf '%s\n' "$LIBOMEMO_C_ADDITIONAL_PERMISSION" > "$permission_fixture"
    permission_hash="$(sha256sum "$permission_fixture" | awk '{ print $1 }')"
    require_libomemo_additional_permission "$permission_fixture" "$permission_hash"
    printf '%s\n' 'tampered' >> "$permission_fixture"
    if (require_libomemo_additional_permission "$permission_fixture" "$permission_hash") \
            >/dev/null 2>&1; then
        fail "self-test accepted a modified libomemo-c additional permission"
    fi

    echo "Self-test OK"
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    usage
    exit 0
fi
if [[ $# -eq 1 && "$1" == "--self-test" ]]; then
    run_self_test
    exit 0
fi

[[ $# -eq 2 ]] || fail "usage: $0 COMPONENT SOURCE_ROOT"
component="$1"
source_root="$2"
app_prefix="${DINOX_FLATPAK_APP_PREFIX:-/app}"
destination="$app_prefix/share/licenses/dinox/third-party/$component"

[[ "$component" =~ ^[a-zA-Z0-9._+-]+$ ]] \
    || fail "invalid component name: $component"
[[ -d "$source_root" ]] || fail "source directory does not exist: $source_root"

mapfile -d '' license_files < <(
    cd "$source_root"
    find . \
        \( -path './.git' -o -path './_flatpak_build' \) -prune -o \
        -type f \
        \( -iname 'COPYING' -o -iname 'COPYING.*' -o -iname 'COPYING-*' \
           -o -iname 'COPYRIGHT' -o -iname 'COPYRIGHT.*' -o -iname 'COPYRIGHT-*' \
           -o -iname 'LICENSE' -o -iname 'LICENSE.*' -o -iname 'LICENSE-*' \
           -o -iname 'LICENCE' -o -iname 'LICENCE.*' -o -iname 'LICENCE-*' \
           -o -iname 'GPL' -o -iname 'GPL.*' -o -iname 'GPL-*' \
           -o -iname 'LGPL' -o -iname 'LGPL.*' -o -iname 'LGPL-*' \
           -o -iname 'AGPL' -o -iname 'AGPL.*' -o -iname 'AGPL-*' \
           -o -iname 'MPL' -o -iname 'MPL.*' -o -iname 'MPL-*' \
           -o -iname 'BSD' -o -iname 'BSD.*' -o -iname 'BSD-*' \
           -o -iname 'MIT' -o -iname 'MIT.*' -o -iname 'MIT-*' \
           -o -iname 'EPL' -o -iname 'EPL.*' -o -iname 'EPL-*' \
           -o -iname 'EDL' -o -iname 'EDL.*' -o -iname 'EDL-*' \
           -o -iname 'NOTICE' -o -iname 'NOTICE.*' -o -iname 'NOTICE-*' \
           -o -iname 'PATENTS' -o -iname 'PATENTS.*' -o -iname 'PATENTS-*' \
           -o -iname 'UNLICENSE' \) \
        -size +0c -print0
)

if [[ "$component" == "libomemo-c" ]]; then
    require_libomemo_additional_permission "$source_root/README.md"
    license_files+=("./README.md")
fi

(( ${#license_files[@]} > 0 )) \
    || fail "no non-empty license or notice files found for $component"

for relative in "${license_files[@]}"; do
    relative="${relative#./}"
    install -Dm0644 \
        "$source_root/$relative" \
        "$destination/$relative"
done

find "$destination" -type f -size +0c -print -quit | grep -q . \
    || fail "no license material was installed for $component"
if [[ "$component" == "libomemo-c" ]]; then
    require_libomemo_additional_permission "$destination/README.md"
fi
echo "Staged Flatpak license material: $component (${#license_files[@]} files)"
