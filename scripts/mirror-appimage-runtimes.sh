#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$PROJECT_ROOT/.appimage-tools"
OUT_DIR="$TOOLS_DIR"
RELEASE_TAG="${RELEASE_TAG:-vendor-deps}"

RUNTIME_BASE_URL="https://github.com/AppImage/type2-runtime/releases/download/continuous"
ARCHES=(x86_64 aarch64)
UPLOAD=false

cleanup() {
    rm -f "$OUT_DIR"/runtime-*.tmp "$OUT_DIR"/runtime-*.sha256.tmp
}
trap cleanup EXIT

usage() {
    cat <<EOF
Usage: $0 [--upload|--self-test]

Downloads AppImage type2 runtime files into:
  $OUT_DIR

Options:
  --upload    Upload runtime files and .sha256 sums to the Forgejo release tag
              from RELEASE_TAG (default: vendor-deps).
  --self-test Validate argument handling and upload token checks without
              downloading or uploading runtime assets.
EOF
}

run_self_test() {
    if ! "$0" --help >/dev/null; then
        echo "Self-test failed: --help did not succeed" >&2
        return 1
    fi

    if "$0" --invalid >/dev/null 2>&1; then
        echo "Self-test failed: accepted an invalid option" >&2
        return 1
    fi

    if env -u FORGEJO_TOKEN -u GITHUB_TOKEN "$0" --upload >/dev/null 2>&1; then
        echo "Self-test failed: accepted --upload without a Forgejo token" >&2
        return 1
    fi

    echo "Self-test OK"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --upload)
            UPLOAD=true
            ;;
        --self-test)
            run_self_test
            exit 0
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
    shift
done

if [ "$UPLOAD" = true ] && [ -z "${FORGEJO_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
    echo "ERROR: FORGEJO_TOKEN is not set; compatible GITHUB_TOKEN fallback is also empty." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

assets=()
for arch in "${ARCHES[@]}"; do
    name="runtime-${arch}"
    url="${RUNTIME_BASE_URL}/${name}"
    dest="${OUT_DIR}/${name}"

    echo "Downloading ${name}..."
    wget -q --show-progress -O "${dest}.tmp" "$url"
    mv "${dest}.tmp" "$dest"
    (cd "$OUT_DIR" \
        && sha256sum "$name" > "${name}.sha256.tmp" \
        && mv "${name}.sha256.tmp" "${name}.sha256" \
        && sha256sum -c "${name}.sha256")

    assets+=("$dest" "${dest}.sha256")
done

echo
echo "Prepared AppImage runtime assets:"
for asset in "${assets[@]}"; do
    echo "  $asset"
done

if [ "$UPLOAD" = true ]; then
    "$PROJECT_ROOT/scripts/forgejo-release.sh" upload "$RELEASE_TAG" "${assets[@]}"
fi
