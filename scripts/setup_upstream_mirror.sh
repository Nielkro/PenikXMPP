#!/usr/bin/env bash
# Rebuild the path-rewritten upstream mirror used for scheduled Conversations syncs.
#
# The upstream repository keeps sources in src/ and fastlane/ while this fork keeps
# them under android/. The mirror branch rewrites those paths once so subsequent
# merges do not report hundreds of mechanical rename conflicts.
#
# The rewritten history has different object ids, so the mirror root is grafted onto
# the original merge-base with `git replace`. Replace refs are local to this clone;
# rerun this script after a fresh clone or when upstream force-pushes.
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://codeberg.org/iNPUTmice/Conversations.git}"
BASE_SHA="${BASE_SHA:-bf3269cd128d4dbf0e479c091477fd9544a798b0}"
WORK_DIR="${WORK_DIR:-/tmp/opencode/upstream-mirror}"
MIRROR_REPO="$(git rev-parse --show-toplevel)"

rm -rf "$WORK_DIR"
git clone --quiet --single-branch --branch master --no-tags "$UPSTREAM_URL" "$WORK_DIR"

pushd "$WORK_DIR" >/dev/null
git filter-repo --force --refs master \
    --path-rename src/:android/src/ \
    --path-rename fastlane/:android/fastlane/ \
    --path-rename libs/:android/libs/ \
    --path-rename build.gradle:android/build.gradle \
    --path-rename settings.gradle:android/settings.gradle \
    --path-rename gradle.properties:android/gradle.properties \
    --path-rename gradle/:android/gradle/ \
    --path-rename gradlew:android/gradlew \
    --path-rename gradlew.bat:android/gradlew.bat \
    --path-rename proguard-rules.pro:android/proguard-rules.pro \
    --path-rename CHANGELOG.md:android/CHANGELOG.md \
    --path-rename conversations.doap:android/conversations.doap
REWRITTEN_BASE="$(awk -v old="$BASE_SHA" '$1 == old { print $2; exit }' .git/filter-repo/commit-map)"
popd >/dev/null

if [ -z "$REWRITTEN_BASE" ]; then
    echo "base commit $BASE_SHA is not present in the rewritten upstream history" >&2
    exit 1
fi

cd "$MIRROR_REPO"
git fetch --force --quiet "$WORK_DIR" HEAD:refs/heads/upstream-sync
git replace --force --graft "$REWRITTEN_BASE" "$BASE_SHA"

echo "upstream-sync rebuilt against $(git log -1 --format='%h %s' upstream-sync)"
echo "grafted $REWRITTEN_BASE onto $BASE_SHA"
