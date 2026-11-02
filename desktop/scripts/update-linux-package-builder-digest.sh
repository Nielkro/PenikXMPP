#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_WORKFLOW="$PROJECT_ROOT/.github/workflows/build.yml"
IMAGE_REF="git.dinox.im/dinoxim/linux-package-builder-dinox"
EXPECTED_PIN_COUNT=3

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage:
  $0 DIGEST [BUILD_WORKFLOW]
  $0 --check DIGEST [BUILD_WORKFLOW]
  $0 --check-current [BUILD_WORKFLOW]
  $0 --extract-push-digest PUSH_LOG
  $0 --self-test

Updates or verifies all immutable Linux package-builder image pins in the
Forgejo build workflow. DIGEST must be in sha256:<64 lowercase hex> form.

The command fails unless exactly $EXPECTED_PIN_COUNT direct container image pins
exist in the expected jobs. Digest extraction accepts exactly one distinct
lowercase sha256 digest from Docker push output.
EOF
}

run_update() {
    local mode="$1"
    local digest="$2"
    local workflow="$3"

    if [ "$mode" != "check-current" ]; then
        [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
            || fail "invalid OCI digest: $digest"
    fi
    [ -f "$workflow" ] || fail "build workflow not found: $workflow"
    command -v python3 >/dev/null 2>&1 || fail "python3 is required"

    python3 - "$mode" "$digest" "$workflow" "$IMAGE_REF" "$EXPECTED_PIN_COUNT" <<'PY'
import os
import pathlib
import re
import stat
import sys
import tempfile

mode, expected_digest, workflow_arg, image_ref, expected_count_arg = sys.argv[1:]
expected_count = int(expected_count_arg)
workflow = pathlib.Path(workflow_arg)
text = workflow.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
expected_jobs = {"release-preflight", "build", "build-appimage"}
job_pattern = re.compile(
    r"^  (?P<job>[A-Za-z0-9_-]+):[ \t]*(?:#.*)?(?:\r?\n)?$"
)
container_pattern = re.compile(
    r"^    container:[ \t]*(?:#.*)?(?:\r?\n)?$"
)
job_property_pattern = re.compile(
    r"^    [A-Za-z0-9_-]+:[ \t]*(?:.*)?(?:\r?\n)?$"
)
image_candidate_pattern = re.compile(
    rf"^[ \t]*image:[ \t]*.*{re.escape(image_ref)}"
)
pin_pattern = re.compile(
    rf"^(?P<prefix>      image:[ \t]*{re.escape(image_ref)}@)"
    r"(?P<digest>sha256:[0-9a-f]{64})"
    r"(?P<suffix>[ \t]*(?:#.*)?)(?P<newline>\r?\n)?$"
)

in_jobs = False
current_job = None
in_container = False
candidates = []
for line_number, line in enumerate(lines):
    if re.fullmatch(r"jobs:[ \t]*(?:#.*)?(?:\r?\n)?", line):
        in_jobs = True
        current_job = None
        in_container = False
        continue
    if in_jobs and line and line[0] not in " \t\r\n#":
        in_jobs = False
        current_job = None
        in_container = False
    if not in_jobs:
        continue

    job_match = job_pattern.fullmatch(line)
    if job_match:
        current_job = job_match.group("job")
        in_container = False
        continue
    if current_job is not None and container_pattern.fullmatch(line):
        in_container = True
        continue
    if current_job is not None and job_property_pattern.fullmatch(line):
        in_container = False
        continue
    if image_candidate_pattern.match(line):
        candidates.append(
            (line_number, current_job, in_container, pin_pattern.fullmatch(line))
        )

if len(candidates) != expected_count:
    raise SystemExit(
        f"FAIL: expected exactly {expected_count} {image_ref} container image "
        f"references in {workflow}, found {len(candidates)}"
    )
candidate_jobs = [job for _, job, _, _ in candidates]
if set(candidate_jobs) != expected_jobs or len(candidate_jobs) != len(set(candidate_jobs)):
    rendered_jobs = ", ".join(str(job) for job in candidate_jobs)
    raise SystemExit(
        "FAIL: Linux package-builder pins must occur exactly once in jobs "
        f"{', '.join(sorted(expected_jobs))}; found: {rendered_jobs}"
    )
if any(not in_container or match is None for _, _, in_container, match in candidates):
    valid_count = sum(
        in_container and match is not None
        for _, _, in_container, match in candidates
    )
    raise SystemExit(
        f"FAIL: all {expected_count} {image_ref} references must be direct "
        f"container.image entries with immutable sha256 digests in {workflow}; "
        f"found {valid_count} valid pins"
    )

pins = [match for _, _, _, match in candidates if match is not None]
current_digests = {match.group("digest") for match in pins}
if len(current_digests) != 1:
    rendered = ", ".join(sorted(current_digests))
    raise SystemExit(
        "FAIL: Linux package-builder pins are already inconsistent; "
        f"found: {rendered}"
    )
if mode == "check-current":
    print(
        f"OK: {expected_count} Linux package-builder pins are structurally "
        f"valid and match {next(iter(current_digests))}"
    )
    raise SystemExit(0)
if mode == "check":
    if current_digests != {expected_digest}:
        rendered = ", ".join(sorted(current_digests))
        raise SystemExit(
            f"FAIL: package-builder pins do not all match {expected_digest}; "
            f"found: {rendered}"
        )
    print(
        f"OK: {expected_count} Linux package-builder pins match "
        f"{expected_digest}"
    )
    raise SystemExit(0)

updated_lines = list(lines)
for line_number, _, _, match in candidates:
    updated_lines[line_number] = (
        f"{match.group('prefix')}{expected_digest}{match.group('suffix')}"
        f"{match.group('newline') or ''}"
    )
updated = "".join(updated_lines)

if updated == text:
    print(
        f"OK: {expected_count} Linux package-builder pins already match "
        f"{expected_digest}"
    )
    raise SystemExit(0)

temporary_fd, temporary_name = tempfile.mkstemp(
    prefix=f".{workflow.name}.digest-update.",
    suffix=".tmp",
    dir=workflow.parent,
)
temporary = pathlib.Path(temporary_name)
try:
    with os.fdopen(temporary_fd, "w", encoding="utf-8", newline="") as stream:
        stream.write(updated)
    os.chmod(temporary, stat.S_IMODE(workflow.stat().st_mode))
    verify_text = temporary.read_text(encoding="utf-8")
    verify_pins = [
        match.group("digest")
        for line in verify_text.splitlines(keepends=True)
        if (match := pin_pattern.fullmatch(line))
    ]
    if verify_pins != [expected_digest] * expected_count:
        raise SystemExit(
            "FAIL: generated workflow did not contain exactly the expected "
            "updated package-builder pins"
        )
    os.replace(temporary, workflow)
finally:
    if temporary.exists():
        temporary.unlink()

print(
    f"Updated {expected_count} Linux package-builder pins to "
    f"{expected_digest}"
)
PY
}

extract_push_digest() {
    local push_log="$1"
    local digest

    [ -f "$push_log" ] || fail "Docker push log not found: $push_log"
    digest="$(
        sed -n -E \
            's/^.*digest: (sha256:[0-9a-f]{64})([[:space:]].*|$)$/\1/p' \
            "$push_log" | sort -u
    )"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
        || fail "Docker push log contains no unique lowercase sha256 digest"
    printf '%s\n' "$digest"
}

run_self_test() {
    local test_root fixture invalid_fixture before_fixture digest_a digest_b
    local mode_before content_before content_after push_log
    test_root="$(mktemp -d)"
    trap 'rm -rf "$test_root"' RETURN
    fixture="$test_root/build.yml"
    invalid_fixture="$test_root/invalid.yml"
    before_fixture="$test_root/before.yml"
    push_log="$test_root/docker-push.log"
    digest_a="sha256:$(printf 'a%.0s' {1..64})"
    digest_b="sha256:$(printf 'b%.0s' {1..64})"

    cat > "$fixture" <<EOF
jobs:
  release-preflight:
    container:
      image: $IMAGE_REF@$digest_a # release gate
  build:
    container:
      image: $IMAGE_REF@$digest_a
  build-appimage:
    container:
      image: $IMAGE_REF@$digest_a
  build-flatpak:
    container:
      image: git.dinox.im/dinoxim/flatpak-builder-dinox@sha256:$(printf 'c%.0s' {1..64})
EOF

    chmod 0640 "$fixture"
    mode_before="$(stat -c %a "$fixture")"
    run_update check-current "" "$fixture"
    run_update update "$digest_b" "$fixture"
    run_update check "$digest_b" "$fixture"
    [ "$(grep -Fc "$IMAGE_REF@$digest_b" "$fixture")" -eq 3 ] \
        || fail "self-test did not update exactly three pins"
    grep -Fq "# release gate" "$fixture" \
        || fail "self-test removed an image-line comment"
    grep -Fq "flatpak-builder-dinox@sha256:" "$fixture" \
        || fail "self-test changed the unrelated Flatpak image"
    [ "$(stat -c %a "$fixture")" = "$mode_before" ] \
        || fail "self-test did not preserve the workflow file mode"

    content_before="$(sha256sum "$fixture")"
    run_update update "$digest_b" "$fixture"
    content_after="$(sha256sum "$fixture")"
    [ "$content_before" = "$content_after" ] \
        || fail "self-test idempotent update changed the workflow"

    if (run_update check "$digest_a" "$fixture") >/dev/null 2>&1; then
        fail "self-test accepted a stale expected digest"
    fi
    if (run_update update "sha256:ABC" "$fixture") >/dev/null 2>&1; then
        fail "self-test accepted an invalid digest"
    fi
    if (run_update update "$digest_a" "$test_root/missing.yml") >/dev/null 2>&1; then
        fail "self-test accepted a missing workflow file"
    fi
    if ("$0" "$digest_a" "$fixture" unexpected) >/dev/null 2>&1; then
        fail "self-test accepted an additional command-line argument"
    fi

    cat > "$push_log" <<EOF
layer: pushed
ubuntu-24.04: digest: $digest_a size: 856
ubuntu-24.04: digest: $digest_a size: 856
EOF
    [ "$(extract_push_digest "$push_log")" = "$digest_a" ] \
        || fail "self-test did not extract the unique Docker push digest"
    printf 'layer only\n' > "$push_log"
    if (extract_push_digest "$push_log") >/dev/null 2>&1; then
        fail "self-test accepted Docker push output without a digest"
    fi
    printf 'a: digest: %s size: 1\nb: digest: %s size: 2\n' \
        "$digest_a" "$digest_b" > "$push_log"
    if (extract_push_digest "$push_log") >/dev/null 2>&1; then
        fail "self-test accepted ambiguous Docker push digests"
    fi
    printf 'tag: digest: sha256:%s size: 1\n' \
        "$(printf 'a%.0s' {1..65})" > "$push_log"
    if (extract_push_digest "$push_log") >/dev/null 2>&1; then
        fail "self-test accepted an overlong Docker push digest"
    fi
    printf 'tag: digest: sha256:%sZ size: 1\n' \
        "$(printf 'a%.0s' {1..63})" > "$push_log"
    if (extract_push_digest "$push_log") >/dev/null 2>&1; then
        fail "self-test accepted a non-hex Docker push digest"
    fi
    printf 'tag: digest: sha256:%s size: 1\n' \
        "$(printf 'A%.0s' {1..64})" > "$push_log"
    if (extract_push_digest "$push_log") >/dev/null 2>&1; then
        fail "self-test accepted an uppercase Docker push digest"
    fi

    cp "$fixture" "$invalid_fixture"
    sed -i "0,/$digest_b/s//$digest_a/" "$invalid_fixture"
    cp "$invalid_fixture" "$before_fixture"
    if (run_update update "$digest_a" "$invalid_fixture") >/dev/null 2>&1; then
        fail "self-test accepted mixed existing package-builder digests"
    fi
    cmp -s "$invalid_fixture" "$before_fixture" \
        || fail "mixed-digest failure changed the workflow"

    cat > "$invalid_fixture" <<EOF
jobs:
  release-preflight:
    container:
      image: $IMAGE_REF@$digest_a
  build:
    container:
      image: $IMAGE_REF:ubuntu-24.04
  build-appimage:
    container:
      image: $IMAGE_REF@$digest_a
EOF
    cp "$invalid_fixture" "$before_fixture"
    if (run_update update "$digest_b" "$invalid_fixture") >/dev/null 2>&1; then
        fail "self-test accepted a mutable package-builder image reference"
    fi
    cmp -s "$invalid_fixture" "$before_fixture" \
        || fail "mutable-reference failure changed the workflow"

    for pin_count in 0 1 2 4; do
        {
            echo "jobs:"
            if [ "$pin_count" -ge 1 ]; then
                printf '  release-preflight:\n    container:\n      image: %s@%s\n' \
                    "$IMAGE_REF" "$digest_a"
            fi
            if [ "$pin_count" -ge 2 ]; then
                printf '  build:\n    container:\n      image: %s@%s\n' \
                    "$IMAGE_REF" "$digest_a"
            fi
            if [ "$pin_count" -ge 3 ]; then
                printf '  build-appimage:\n    container:\n      image: %s@%s\n' \
                    "$IMAGE_REF" "$digest_a"
            fi
            if [ "$pin_count" -ge 4 ]; then
                printf '  unexpected:\n    container:\n      image: %s@%s\n' \
                    "$IMAGE_REF" "$digest_a"
            fi
        } > "$invalid_fixture"
        cp "$invalid_fixture" "$before_fixture"
        if (run_update update "$digest_b" "$invalid_fixture") >/dev/null 2>&1; then
            fail "self-test accepted $pin_count package-builder pins"
        fi
        cmp -s "$invalid_fixture" "$before_fixture" \
            || fail "$pin_count-pin failure changed the workflow"
    done

    cat > "$invalid_fixture" <<EOF
jobs:
  wrong-release:
    container:
      image: $IMAGE_REF@$digest_a
  wrong-build:
    container:
      image: $IMAGE_REF@$digest_a
  wrong-appimage:
    container:
      image: $IMAGE_REF@$digest_a
EOF
    cp "$invalid_fixture" "$before_fixture"
    if (run_update update "$digest_b" "$invalid_fixture") >/dev/null 2>&1; then
        fail "self-test accepted package-builder pins in the wrong jobs"
    fi
    cmp -s "$invalid_fixture" "$before_fixture" \
        || fail "wrong-job failure changed the workflow"

    cat > "$invalid_fixture" <<EOF
jobs:
  release-preflight:
    services:
      image: $IMAGE_REF@$digest_a
  build:
    services:
      image: $IMAGE_REF@$digest_a
  build-appimage:
    services:
      image: $IMAGE_REF@$digest_a
EOF
    cp "$invalid_fixture" "$before_fixture"
    if (run_update update "$digest_b" "$invalid_fixture") >/dev/null 2>&1; then
        fail "self-test accepted image pins outside direct container blocks"
    fi
    cmp -s "$invalid_fixture" "$before_fixture" \
        || fail "wrong-container failure changed the workflow"

    echo "Self-test OK"
    rm -rf "$test_root"
    trap - RETURN
}

case "${1:-}" in
    --self-test)
        [ "$#" -eq 1 ] || fail "--self-test accepts no additional arguments"
        run_self_test
        ;;
    --check)
        [ "$#" -ge 2 ] && [ "$#" -le 3 ] \
            || fail "--check requires DIGEST and optionally BUILD_WORKFLOW"
        run_update check "$2" "${3:-$DEFAULT_WORKFLOW}"
        ;;
    --check-current)
        [ "$#" -le 2 ] \
            || fail "--check-current accepts only an optional BUILD_WORKFLOW"
        run_update check-current "" "${2:-$DEFAULT_WORKFLOW}"
        ;;
    --extract-push-digest)
        [ "$#" -eq 2 ] || fail "--extract-push-digest requires PUSH_LOG"
        extract_push_digest "$2"
        ;;
    --help|-h)
        [ "$#" -eq 1 ] || fail "--help accepts no additional arguments"
        usage
        ;;
    "")
        usage >&2
        exit 2
        ;;
    -*)
        fail "unknown option: $1"
        ;;
    *)
        [ "$#" -le 2 ] || fail "too many arguments"
        run_update update "$1" "${2:-$DEFAULT_WORKFLOW}"
        ;;
esac
