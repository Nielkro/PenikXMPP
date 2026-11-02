#!/bin/bash
# Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# Release script for DinoX

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 <version> [--prepare|--finalize]|--self-test"
    echo "Example prepare:  $0 2.0.9"
    echo "Example finalize: $0 2.0.9 --finalize"
    echo ""
    echo "Release flow:"
    echo "  1. --prepare updates release metadata, runs the local release gate,"
    echo "     commits the release tree and pushes that commit without a tag."
    echo "  2. --finalize verifies the pushed release commit and pushes the tag."
    echo "  3. The single Forgejo tag workflow builds and publishes all Linux packages."
}

ensure_clean_tree() {
    # Include untracked files so release edits never mix with local work.
    if [ -n "$(git status --porcelain)" ]; then
        echo -e "${RED}ERROR: You have local changes${NC}"
        echo "Please commit or stash your changes first"
        git status --short
        exit 1
    fi
}

validate_version_format() {
    local version="$1"
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo -e "${RED}ERROR: Invalid version format: $version${NC}"
        echo "Version must be in format: X.Y.Z or X.Y.Z.W (e.g., 0.6.0 or 0.8.6.10)"
        exit 2
    fi
}

validate_release_tree() {
    local version="$1"
    local failed=false

    if [ "$(cat VERSION 2>/dev/null || true)" != "$version" ]; then
        echo -e "${RED}ERROR: VERSION is not $version${NC}" >&2
        failed=true
    fi

    if ! grep -q "project('Dino'.*version: '$version'" meson.build; then
        echo -e "${RED}ERROR: meson.build project version is not $version${NC}" >&2
        failed=true
    fi

    if ! python3 "$SCRIPT_DIR/release-metadata.py" check-stable "$version"; then
        failed=true
    fi

    if [ "$failed" = "true" ]; then
        exit 1
    fi
}

run_local_release_gate() {
    echo -e "${YELLOW}Running local release gate on the release tree...${NC}"
    ./scripts/run_all_tests.sh --static

    if [ -z "${DINOX_LIBWEBRTC_RUNTIME_ROOT:-}" ]; then
        echo -e "${RED}ERROR: DINOX_LIBWEBRTC_RUNTIME_ROOT is required for the release gate${NC}" >&2
        exit 1
    fi
    scripts/check-libwebrtc-linux-runtime.sh "$DINOX_LIBWEBRTC_RUNTIME_ROOT"
    local local_libomemo_c_root="${DINOX_LOCAL_LIBOMEMO_C_ROOT:-$PWD/.vendor-deps/linux-source-deps}"
    local libomemo_args=()
    if [ -d "$local_libomemo_c_root" ]; then
        local_libomemo_c_root="$(cd "$local_libomemo_c_root" && pwd -P)"
        export PKG_CONFIG_PATH="$local_libomemo_c_root/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
        if ! pkg-config --exact-version=0.5.1 libomemo-c; then
            echo -e "${RED}ERROR: $local_libomemo_c_root does not provide libomemo-c 0.5.1${NC}" >&2
            exit 1
        fi
        libomemo_args+=("-Dlocal-libomemo-c-root=$local_libomemo_c_root")
    elif ! pkg-config --exact-version=0.5.1 libomemo-c; then
        echo -e "${RED}ERROR: pinned libomemo-c 0.5.1 is required; run scripts/prepare-linux-source-build-deps.sh${NC}" >&2
        exit 1
    fi
    local media_args=(
        "${libomemo_args[@]}"
        -Dplugin-rtp=disabled
        -Dplugin-google-webrtc=enabled
        -Dgoogle-libwebrtc-wrapper=enabled
        "-Dgoogle-libwebrtc-runtime-root=$DINOX_LIBWEBRTC_RUNTIME_ROOT"
        -Dgoogle-libwebrtc-test-oracle=false
        -Dgoogle-libwebrtc-tests=false
        -Dplugin-rtp-vaapi=disabled
        -Dplugin-http-files=enabled
        -Dplugin-ice=enabled
        -Dplugin-omemo=enabled
        -Dplugin-openpgp=enabled
        -Dplugin-notification-sound=enabled
    )
    if [ -d build/meson-private ]; then
        meson setup --wipe --prefix=/usr --buildtype=debugoptimized build \
            -Dplugin-mqtt=enabled \
            "${media_args[@]}" \
            -Dlocation-sharing=enabled
    else
        meson setup --prefix=/usr --buildtype=debugoptimized build \
            -Dplugin-mqtt=enabled \
            "${media_args[@]}" \
            -Dlocation-sharing=enabled
    fi

    # The shared runner checks production and test graphs independently with
    # strict warnings and restores the production graph on every exit path.
    ./scripts/run_all_tests.sh --meson

    if ! command -v sqlcipher >/dev/null 2>&1; then
        echo -e "${RED}ERROR: sqlcipher is required for the release DB gate${NC}" >&2
        exit 1
    fi
    ./scripts/run_all_tests.sh --db

    ./scripts/package-runtime-matrix.sh system
    ./scripts/package-runtime-matrix.sh metadata
    ./scripts/package-runtime-matrix.sh flatpak-manifest im.dinox.dinox.json
}

run_self_test() {
    if ! "$0" --help >/dev/null; then
        echo "Self-test failed: --help did not succeed" >&2
        return 1
    fi

    if "$0" >/dev/null 2>&1; then
        echo "Self-test failed: accepted a missing version argument" >&2
        return 1
    fi

    if "$0" 1.2.3 --invalid >/dev/null 2>&1; then
        echo "Self-test failed: accepted an invalid mode" >&2
        return 1
    fi

    if "$0" 1.2.3 --prepare extra >/dev/null 2>&1; then
        echo "Self-test failed: accepted too many arguments" >&2
        return 1
    fi

    validate_version_format 1.2.3
    validate_version_format 1.2.3.4

    if (validate_version_format 1.2) >/dev/null 2>&1; then
        echo "Self-test failed: accepted an incomplete version" >&2
        return 1
    fi

    if (validate_version_format v1.2.3) >/dev/null 2>&1; then
        echo "Self-test failed: accepted a version with v prefix" >&2
        return 1
    fi

    if (validate_version_format 1.2.3.4.5) >/dev/null 2>&1; then
        echo "Self-test failed: accepted too many version components" >&2
        return 1
    fi

    python3 "$SCRIPT_DIR/release-metadata.py" self-test
    echo "Self-test OK"
}

if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage
    exit 0
fi

if [ "$#" -eq 1 ] && [ "$1" = "--self-test" ]; then
    run_self_test
    exit 0
fi

# Get version from argument
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo -e "${RED}ERROR: expected a version and optional release mode${NC}" >&2
    usage >&2
    exit 2
fi
VERSION="$1"
MODE="${2:---prepare}"

case "$MODE" in
    --prepare|--finalize)
        ;;
    *)
        echo -e "${RED}ERROR: unknown release mode: $MODE${NC}" >&2
        usage >&2
        exit 2
        ;;
esac

# Validate version format
validate_version_format "$VERSION"

TAG="v$VERSION"

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}DinoX Release Script${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo -e "Version: ${YELLOW}$VERSION${NC}"
echo -e "Tag:     ${YELLOW}$TAG${NC}"
echo -e "Mode:    ${YELLOW}${MODE#--}${NC}"
echo ""

ensure_clean_tree

# Check if we're on master
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "master" ]; then
    echo -e "${YELLOW}WARNING: Not on master branch (currently on: $CURRENT_BRANCH)${NC}"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check if tag already exists
if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
    echo -e "${RED}ERROR: Tag $TAG already exists${NC}"
    echo "Use 'git tag -d $TAG' to delete it first if needed"
    exit 1
fi

if [ "$MODE" = "--finalize" ]; then
    validate_release_tree "$VERSION"
    COMMIT_SHA="$(git rev-parse HEAD)"
    git fetch --quiet origin "$CURRENT_BRANCH:refs/remotes/origin/$CURRENT_BRANCH"
    REMOTE_SHA="$(git rev-parse "origin/$CURRENT_BRANCH")"
    if [ "$COMMIT_SHA" != "$REMOTE_SHA" ]; then
        echo -e "${RED}ERROR: local release commit is not the current origin/$CURRENT_BRANCH${NC}" >&2
        echo "Local:  $COMMIT_SHA" >&2
        echo "Remote: $REMOTE_SHA" >&2
        echo "Pull/rebase or check out the pushed release commit before finalizing." >&2
        exit 1
    fi

    git tag -a "$TAG" -m "Release DinoX v$VERSION

See CHANGELOG.md for details."
    echo -e "${GREEN}[OK]${NC} Created tag $TAG"

    echo ""
    echo -e "${YELLOW}Ready to push release tag:${NC}"
    echo "  - Commit: $(git rev-parse --short HEAD)"
    echo "  - Tag: $TAG"
    echo ""
    echo -e "${YELLOW}This will:${NC}"
    echo "  1. Push only the release tag to Forgejo"
    echo "  2. Trigger the Forgejo Actions tag workflow"
    echo "  3. Build Debian, AppImage and Flatpak release packages"
    echo "  4. Create or update the Forgejo release with checksummed assets"
    echo ""

    read -p "Push tag to Forgejo and start package release build? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git push origin "$TAG"
        echo -e "${GREEN}[OK]${NC} Pushed tag"
        echo ""
        echo -e "${GREEN}Release package build started.${NC}"
        echo -e "Track progress at: ${YELLOW}https://git.dinox.im/dinoxim/dinox/actions${NC}"
        echo -e "Release URL:       ${YELLOW}https://git.dinox.im/dinoxim/dinox/releases/tag/$TAG${NC}"
    else
        echo -e "${YELLOW}Aborted. Local tag was created but not pushed.${NC}"
        echo "Remove it with: git tag -d $TAG"
        exit 1
    fi

    exit 0
fi

# Promote an already prepared entry or create it once. XML validation and
# duplicate detection happen before any release metadata is written.
TODAY=$(date +%Y-%m-%d)
python3 "$SCRIPT_DIR/release-metadata.py" prepare "$VERSION" --date "$TODAY"
echo -e "${GREEN}[OK]${NC} Prepared CHANGELOG, DOAP and stable AppStream entry"

# Update VERSION file
echo "$VERSION" > VERSION
echo -e "${GREEN}[OK]${NC} Updated VERSION → $VERSION"

# Keep Meson's project version aligned with the release version.
if [ -f meson.build ]; then
    sed -i -E "0,/version: '[^']*'/{s/version: '[^']*'/version: '$VERSION'/}" meson.build
    if ! grep -q "project('Dino'.*version: '$VERSION'" meson.build; then
        echo -e "${RED}ERROR: Failed to update meson.build project version${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}[OK]${NC} Updated meson.build project version"
fi

run_local_release_gate

# Commit release update
git add VERSION meson.build docs/internal/CHANGELOG.md dino.doap main/data/im.dinox.dinox.appdata.xml
git commit -m "chore: Release version $VERSION

Release: DinoX v$VERSION

See CHANGELOG.md for full details."
echo -e "${GREEN}[OK]${NC} Committed version bump"

# Show what will be pushed
echo ""
echo -e "${YELLOW}Ready to push release commit:${NC}"
echo "  - Commit: $(git rev-parse --short HEAD)"
echo ""
echo -e "${YELLOW}This will:${NC}"
echo "  1. Push only the release commit to Forgejo"
echo "  2. NOT push the tag yet"
echo "  3. Let you review the exact pushed commit before finalizing"
echo ""

read -p "Push release commit to Forgejo? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    git push origin "$CURRENT_BRANCH"
    echo -e "${GREEN}[OK]${NC} Pushed commit"

    COMMIT_SHA="$(git rev-parse HEAD)"
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}Release commit prepared.${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    echo -e "Finalize directly with:"
    echo -e "  ${YELLOW}./scripts/release.sh $VERSION --finalize${NC}"
    echo ""
    echo -e "Do not start a manual release_tag or release_candidate workflow."
    echo -e "The pushed tag starts the single Linux release build."
    echo ""
    echo -e "Expected release commit SHA:"
    echo -e "  ${YELLOW}$COMMIT_SHA${NC}"
else
    echo -e "${YELLOW}Aborted.${NC}"
    echo ""
    echo "To undo the local release commit while keeping files for review:"
    echo "  git reset --mixed HEAD~1"
    exit 1
fi
