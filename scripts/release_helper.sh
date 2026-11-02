#!/bin/bash
# Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# DinoX Release Helper Script
# Usage: ./scripts/release_helper.sh <version>
# Example: ./scripts/release_helper.sh 0.6.3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <version>|--self-test"
    echo "Example: $0 0.6.3"
}

ensure_clean_tree() {
    # Include untracked files so release edits never mix with local work.
    if [ -n "$(git status --porcelain)" ]; then
        echo "ERROR: You have local changes"
        echo "Please commit or stash your changes first"
        git status --short
        exit 1
    fi
}

validate_version_format() {
    local version="$1"
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "ERROR: Invalid version format: $version (expected: X.Y.Z or X.Y.Z.W)"
        exit 2
    fi
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

    if "$0" 1.2.3 extra >/dev/null 2>&1; then
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

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 2
fi

VERSION="$1"

# Validate version format
validate_version_format "$VERSION"

DATE=$(date +%Y-%m-%d)
READABLE_DATE=$(date "+%B %d, %Y")

echo "Preparing release v$VERSION ($DATE)..."

ensure_clean_tree

./scripts/run_all_tests.sh --static

# Promote existing prepared metadata, retaining its release notes and history.
python3 "$SCRIPT_DIR/release-metadata.py" prepare "$VERSION" --date "$DATE"
echo "Updated CHANGELOG, DOAP and stable AppStream entry"

# 2. Update DEVELOPMENT_PLAN.md
if [ -f docs/internal/DEVELOPMENT_PLAN.md ]; then
    sed -i "s/> \*\*Version\*\*: .*/> **Version**: $VERSION/" docs/internal/DEVELOPMENT_PLAN.md
    sed -i "s/> \*\*Last Updated\*\*: .*/> **Last Updated**: $READABLE_DATE/" docs/internal/DEVELOPMENT_PLAN.md
    echo "Updated docs/internal/DEVELOPMENT_PLAN.md"
else
    echo "WARNING: docs/internal/DEVELOPMENT_PLAN.md not found, skipping"
fi

./scripts/package-runtime-matrix.sh metadata
./scripts/package-runtime-matrix.sh flatpak-manifest im.dinox.dinox.json

echo "------------------------------------------------"
echo "Release v$VERSION prepared successfully!"
echo "Please review the changes:"
echo "  - docs/internal/CHANGELOG.md"
echo "  - docs/internal/DEVELOPMENT_PLAN.md"
echo "  - main/data/im.dinox.dinox.appdata.xml"
echo ""
echo "Next steps:"
echo "1. For official releases, use ./scripts/release.sh $VERSION --prepare instead of manual tagging."
echo "2. Review the pushed release commit, then finalize with:"
echo "   ./scripts/release.sh $VERSION --finalize"
echo "3. The tag starts the single Forgejo Linux release workflow; do not start a second manual release_tag run."
echo "------------------------------------------------"
