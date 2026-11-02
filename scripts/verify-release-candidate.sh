#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage:
  $0 <commit-sha>
  $0 --self-test
  $0 -h|--help

Environment:
  DINOX_RELEASE_CANDIDATE_RUN  Optional Forgejo action run id or repository
                               action number. If omitted, the script searches
                               for a valid green RC on the exact commit SHA.
  DINOX_RELEASE_CANDIDATE_REF  Expected dispatch ref, default refs/heads/master.
  FORGEJO_TOKEN                Optional Forgejo API token. GITHUB_TOKEN and
                               DINOX_REGISTRY_TOKEN are accepted as fallbacks;
                               public read-only API access is used if token
                               access fails or no token is set.

The checked run must be a successful Build workflow_dispatch run on the exact
commit SHA with release_candidate=true, all Linux package jobs enabled, no
release_tag, and successful Core/AppImage/Flatpak tasks. Meson test suites must
pass in the local release gate before this package workflow is dispatched.
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

validate_sha() {
    local sha="$1"
    if ! [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
        fail "commit SHA must be a full 40-character SHA: $sha"
    fi
}

validate_run_reference() {
    local run_ref="$1"
    if ! [[ "$run_ref" =~ ^[0-9]+$ ]]; then
        fail "DINOX_RELEASE_CANDIDATE_RUN must be numeric: $run_ref"
    fi
}

validate_run_json() {
    local expected_sha="$1"
    local expected_ref="$2"
    local run_json
    run_json="$(cat)"

    RUN_JSON="$run_json" python3 - "$expected_sha" "$expected_ref" <<'PY'
import json
import os
import sys

expected_sha = sys.argv[1].lower()
expected_ref = sys.argv[2]
run = json.loads(os.environ["RUN_JSON"])
errors = []

def truthy(value):
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "on"}

def as_text(value):
    return "" if value is None else str(value)

workflow_id = as_text(run.get("workflow_id"))
if workflow_id != "build.yml":
    errors.append(f"workflow_id is {workflow_id!r}, expected 'build.yml'")

status = as_text(run.get("status"))
if status != "success":
    errors.append(f"run status is {status!r}, expected 'success'")

trigger_event = as_text(run.get("trigger_event") or run.get("event"))
if trigger_event != "workflow_dispatch":
    errors.append(f"trigger_event is {trigger_event!r}, expected 'workflow_dispatch'")

commit_sha = as_text(run.get("commit_sha") or run.get("head_sha")).lower()
if commit_sha != expected_sha:
    errors.append(f"commit_sha is {commit_sha!r}, expected {expected_sha!r}")

payload_raw = run.get("event_payload") or "{}"
try:
    payload = json.loads(payload_raw) if isinstance(payload_raw, str) else payload_raw
except json.JSONDecodeError as exc:
    errors.append(f"event_payload is not valid JSON: {exc}")
    payload = {}

if not isinstance(payload, dict):
    errors.append("event_payload is not an object")
    payload = {}

payload_ref = as_text(payload.get("ref"))
if payload_ref != expected_ref:
    errors.append(f"event_payload.ref is {payload_ref!r}, expected {expected_ref!r}")

inputs = payload.get("inputs", {})
if not isinstance(inputs, dict):
    errors.append("event_payload.inputs is missing or not an object")
    inputs = {}

required_true = [
    "release_candidate",
    "build_deb",
    "build_appimage",
    "build_flatpak",
]
for key in required_true:
    if not truthy(inputs.get(key)):
        errors.append(f"input {key} is {inputs.get(key)!r}, expected true")

if as_text(inputs.get("release_tag")).strip():
    errors.append("input release_tag must be empty for a release candidate run")

if truthy(inputs.get("mirror_appimage_runtimes")):
    errors.append("input mirror_appimage_runtimes must be false for a release candidate run")

if errors:
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    sys.exit(1)

run_id = run.get("id", "unknown")
run_number = run.get("index_in_repo", "unknown")
html_url = run.get("html_url", "")
print(f"OK: release candidate run id={run_id} number={run_number} commit={commit_sha}")
if html_url:
    print(f"URL: {html_url}")
PY
}

validate_tasks_json() {
    local expected_sha="$1"
    local expected_run_number="$2"
    local tasks_file
    local rc=0
    tasks_file="$(mktemp)"
    cat > "$tasks_file"
    trap 'rm -f "$tasks_file"' RETURN

    python3 - "$expected_sha" "$expected_run_number" "$tasks_file" <<'PY' || rc=$?
import json
import sys

expected_sha = sys.argv[1].lower()
expected_run_number = str(sys.argv[2])
tasks_file = sys.argv[3]
with open(tasks_file, "r", encoding="utf-8") as handle:
    data = json.load(handle)
tasks = data.get("workflow_runs", [])
required = {
    "Validate Manual Selection": False,
    "Core Build": False,
    "Build AppImage": False,
    "Build Flatpak": False,
}
seen = {}

for task in tasks:
    if str(task.get("run_number")) != expected_run_number:
        continue
    if str(task.get("workflow_id")) != "build.yml":
        continue
    if str(task.get("event")) != "workflow_dispatch":
        continue
    if str(task.get("head_sha", "")).lower() != expected_sha:
        continue

    name = str(task.get("name", ""))
    status = str(task.get("status", ""))
    seen[name] = status
    if name in required and status == "success":
        required[name] = True

missing = [name for name, ok in required.items() if not ok]
if missing:
    for name in missing:
        print(
            f"FAIL: task {name!r} is {seen.get(name, 'missing')!r}, expected 'success'",
            file=sys.stderr,
        )
    sys.exit(1)

print("OK: release candidate tasks successful")
PY
    rm -f "$tasks_file"
    trap - RETURN
    return "$rc"
}

run_number_from_run_json() {
    local run_json
    run_json="$(cat)"
    RUN_JSON="$run_json" python3 - <<'PY'
import json
import os

run = json.loads(os.environ["RUN_JSON"])
print(run.get("index_in_repo") or run.get("run_number") or "")
PY
}

run_self_test() {
    local sha="0123456789abcdef0123456789abcdef01234567"
    local valid_json
    local tasks_json
    local failed_tasks_json
    valid_json="$(cat <<EOF
{
  "id": 123,
  "index_in_repo": 45,
  "workflow_id": "build.yml",
  "status": "success",
  "trigger_event": "workflow_dispatch",
  "commit_sha": "$sha",
  "event_payload": "{\"ref\":\"refs/heads/master\",\"inputs\":{\"release_candidate\":\"true\",\"build_deb\":\"true\",\"build_appimage\":\"true\",\"build_flatpak\":\"true\",\"mirror_appimage_runtimes\":\"false\",\"release_tag\":\"\"}}"
}
EOF
)"
    failed_tasks_json="$(cat <<EOF
{
  "workflow_runs": [
    {"name":"Validate Manual Selection","head_sha":"$sha","run_number":45,"event":"workflow_dispatch","workflow_id":"build.yml","status":"success"},
    {"name":"Core Build","head_sha":"$sha","run_number":45,"event":"workflow_dispatch","workflow_id":"build.yml","status":"success"},
    {"name":"Build AppImage","head_sha":"$sha","run_number":45,"event":"workflow_dispatch","workflow_id":"build.yml","status":"success"},
    {"name":"Build Flatpak","head_sha":"$sha","run_number":45,"event":"workflow_dispatch","workflow_id":"build.yml","status":"failure"}
  ]
}
EOF
)"
    tasks_json="$(cat <<EOF
{
  "workflow_runs": [
    {"name":"Validate Manual Selection","head_sha":"$sha","run_number":45,"event":"workflow_dispatch","workflow_id":"build.yml","status":"success"},
    {"name":"Core Build","head_sha":"$sha","run_number":45,"event":"workflow_dispatch","workflow_id":"build.yml","status":"success"},
    {"name":"Build AppImage","head_sha":"$sha","run_number":45,"event":"workflow_dispatch","workflow_id":"build.yml","status":"success"},
    {"name":"Build Flatpak","head_sha":"$sha","run_number":45,"event":"workflow_dispatch","workflow_id":"build.yml","status":"success"}
  ]
}
EOF
)"

    if ! "$0" --help >/dev/null; then
        echo "Self-test failed: --help did not succeed" >&2
        return 1
    fi

    validate_sha "$sha"
    validate_run_reference 12345
    validate_run_json "$sha" "refs/heads/master" <<<"$valid_json" >/dev/null
    validate_tasks_json "$sha" 45 <<<"$tasks_json" >/dev/null

    if (validate_sha 1234) >/dev/null 2>&1; then
        echo "Self-test failed: accepted a short SHA" >&2
        return 1
    fi

    if (validate_run_reference abc) >/dev/null 2>&1; then
        echo "Self-test failed: accepted a non-numeric run reference" >&2
        return 1
    fi

    if (validate_run_json "ffffffffffffffffffffffffffffffffffffffff" "refs/heads/master" <<<"$valid_json") >/dev/null 2>&1; then
        echo "Self-test failed: accepted the wrong commit SHA" >&2
        return 1
    fi

    if (sed 's/"status": "success"/"status": "failure"/' <<<"$valid_json" | validate_run_json "$sha" "refs/heads/master") >/dev/null 2>&1; then
        echo "Self-test failed: accepted a failed run" >&2
        return 1
    fi

    if (sed 's/\\"release_candidate\\":\\"true\\"/\\"release_candidate\\":\\"false\\"/' <<<"$valid_json" | validate_run_json "$sha" "refs/heads/master") >/dev/null 2>&1; then
        echo "Self-test failed: accepted a non-RC run" >&2
        return 1
    fi

    if (sed 's/\\"release_tag\\":\\"\\"/\\"release_tag\\":\\"v1.2.3\\"/' <<<"$valid_json" | validate_run_json "$sha" "refs/heads/master") >/dev/null 2>&1; then
        echo "Self-test failed: accepted a run with release uploads enabled" >&2
        return 1
    fi

    if (validate_tasks_json "$sha" 45 <<<"$failed_tasks_json") >/dev/null 2>&1; then
        echo "Self-test failed: accepted a failed required task" >&2
        return 1
    fi

    echo "Self-test OK"
}

fetch_url() {
    local url="$1"
    if [ -n "$TOKEN" ]; then
        if curl -fsS --max-time 60 -H "Authorization: token ${TOKEN}" "$url"; then
            return 0
        fi
        echo "WARN: authenticated Forgejo API request failed; retrying without token" >&2
    fi
    curl -fsS --max-time 60 "$url"
}

api_url() {
    printf '%s/repos/%s%s' "$API_URL" "$REPOSITORY" "$1"
}

select_run_from_list() {
    local runs_json="$1"
    local expected_sha="$2"
    local expected_ref="$3"
    local run_ref="${4:-}"
    local runs_file
    local rc=0
    runs_file="$(mktemp)"
    printf '%s\n' "$runs_json" > "$runs_file"
    trap 'rm -f "$runs_file"' RETURN

    python3 - "$expected_sha" "$expected_ref" "$run_ref" "$runs_file" <<'PY' || rc=$?
import json
import sys

expected_sha = sys.argv[1].lower()
expected_ref = sys.argv[2]
run_ref = sys.argv[3]
runs_file = sys.argv[4]
with open(runs_file, "r", encoding="utf-8") as handle:
    data = json.load(handle)
runs = data.get("workflow_runs", [])

def truthy(value):
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "on"}

def as_text(value):
    return "" if value is None else str(value)

def valid(run):
    if run_ref and not (
        str(run.get("id")) == run_ref or str(run.get("index_in_repo")) == run_ref
    ):
        return False
    if as_text(run.get("workflow_id")) != "build.yml":
        return False
    if as_text(run.get("status")) != "success":
        return False
    if as_text(run.get("trigger_event") or run.get("event")) != "workflow_dispatch":
        return False
    if as_text(run.get("commit_sha") or run.get("head_sha")).lower() != expected_sha:
        return False
    try:
        payload = json.loads(run.get("event_payload") or "{}")
    except json.JSONDecodeError:
        return False
    if not isinstance(payload, dict) or as_text(payload.get("ref")) != expected_ref:
        return False
    inputs = payload.get("inputs", {})
    if not isinstance(inputs, dict):
        return False
    for key in ["release_candidate", "build_deb", "build_appimage", "build_flatpak"]:
        if not truthy(inputs.get(key)):
            return False
    if as_text(inputs.get("release_tag")).strip():
        return False
    if truthy(inputs.get("mirror_appimage_runtimes")):
        return False
    return True

candidates = [run for run in runs if valid(run)]
if not candidates:
    if run_ref:
        print(
            f"ERROR: no successful release-candidate run found for run reference {run_ref} on commit {expected_sha}",
            file=sys.stderr,
        )
    else:
        print(
            f"ERROR: no successful release-candidate run found on commit {expected_sha}",
            file=sys.stderr,
        )
    sys.exit(1)

candidates.sort(key=lambda run: int(run.get("id") or 0), reverse=True)
print(json.dumps(candidates[0]))
PY
    rm -f "$runs_file"
    trap - RETURN
    return "$rc"
}

fetch_run_json() {
    local expected_sha="$1"
    local expected_ref="$2"
    local run_ref="${3:-}"
    local runs_json
    local direct_json

    if [ -n "$run_ref" ]; then
        if direct_json="$(fetch_url "$(api_url "/actions/runs/${run_ref}")" 2>/dev/null)"; then
            if validate_run_json "$expected_sha" "$expected_ref" <<<"$direct_json" >/dev/null 2>&1; then
                printf '%s\n' "$direct_json"
                return 0
            fi
        fi
    fi

    runs_json="$(fetch_runs_json)"
    select_run_from_list "$runs_json" "$expected_sha" "$expected_ref" "$run_ref"
}

fetch_runs_json() {
    local combined_file
    local page_file
    local page
    combined_file="$(mktemp)"
    page_file="$(mktemp)"
    trap 'rm -f "$combined_file" "$page_file"' RETURN
    printf '{"workflow_runs":[]}\n' > "$combined_file"

    for page in 1 2 3 4 5; do
        fetch_url "$(api_url "/actions/runs?workflow_id=build.yml&limit=100&page=${page}")" > "$page_file"
        python3 - "$combined_file" "$page_file" <<'PY'
import json
import sys

combined_file, page_file = sys.argv[1], sys.argv[2]
with open(combined_file, "r", encoding="utf-8") as handle:
    combined = json.load(handle)
with open(page_file, "r", encoding="utf-8") as handle:
    page = json.load(handle)
combined.setdefault("workflow_runs", []).extend(page.get("workflow_runs", []))
with open(combined_file, "w", encoding="utf-8") as handle:
    json.dump(combined, handle)
PY
    done

    cat "$combined_file"
    rm -f "$combined_file" "$page_file"
    trap - RETURN
}

fetch_tasks_json() {
    local run_number="$1"
    local combined_file
    local page_file
    local page
    combined_file="$(mktemp)"
    page_file="$(mktemp)"
    trap 'rm -f "$combined_file" "$page_file"' RETURN
    printf '{"workflow_runs":[]}\n' > "$combined_file"

    for page in 1 2 3 4 5; do
        fetch_url "$(api_url "/actions/tasks?limit=200&page=${page}")" > "$page_file"
        python3 - "$combined_file" "$page_file" <<'PY'
import json
import sys

combined_file, page_file = sys.argv[1], sys.argv[2]
with open(combined_file, "r", encoding="utf-8") as handle:
    combined = json.load(handle)
with open(page_file, "r", encoding="utf-8") as handle:
    page = json.load(handle)
combined.setdefault("workflow_runs", []).extend(page.get("workflow_runs", []))
with open(combined_file, "w", encoding="utf-8") as handle:
    json.dump(combined, handle)
PY
    done

    cat "$combined_file"
    rm -f "$combined_file" "$page_file"
    trap - RETURN
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

EXPECTED_SHA="$1"
validate_sha "$EXPECTED_SHA"
EXPECTED_REF="${DINOX_RELEASE_CANDIDATE_REF:-refs/heads/master}"

RUN_REF="${DINOX_RELEASE_CANDIDATE_RUN:-}"
if [ -n "$RUN_REF" ]; then
    validate_run_reference "$RUN_REF"
fi

REPOSITORY="${FORGEJO_REPOSITORY:-${GITHUB_REPOSITORY:-dinoxim/dinox}}"
SERVER_URL="${FORGEJO_SERVER_URL:-${GITHUB_SERVER_URL:-https://git.dinox.im}}"
API_URL="${FORGEJO_API_URL:-${SERVER_URL%/}/api/v1}"
TOKEN="${FORGEJO_TOKEN:-${GITHUB_TOKEN:-${DINOX_REGISTRY_TOKEN:-}}}"

if ! run_json="$(fetch_run_json "$EXPECTED_SHA" "$EXPECTED_REF" "$RUN_REF")"; then
    exit 1
fi
validate_run_json "$EXPECTED_SHA" "$EXPECTED_REF" <<<"$run_json"

run_number="$(run_number_from_run_json <<<"$run_json")"
if [ -z "$run_number" ]; then
    fail "selected release-candidate run has no index_in_repo/run_number"
fi

if ! tasks_json="$(fetch_tasks_json "$run_number")"; then
    exit 1
fi
validate_tasks_json "$EXPECTED_SHA" "$run_number" <<<"$tasks_json"
