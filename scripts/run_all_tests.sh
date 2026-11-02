#!/bin/bash
# DinoX -- Complete Test Runner
# Runs all automated tests and displays a summary.
#
# Usage:
#   ./scripts/run_all_tests.sh          # static checks, strict build, Meson tests, DB tests
#   ./scripts/run_all_tests.sh --static # documentation, translation syntax, Unicode scan, Python/shell syntax, runner/release/mirror/RC/libwebrtc/builder-digest self-tests, runtime matrix self-test, package metadata and Flatpak manifest checks only
#   ./scripts/run_all_tests.sh --meson  # strict build + all Meson tests only
#   ./scripts/run_all_tests.sh --db     # DB tests only
#   ./scripts/run_all_tests.sh --self-test # runner argument validation only
#
# Exit code: 0 if all pass, 1 if any fail.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

usage() {
    echo "Usage: $0 [--static|--meson|--db|--self-test|--help]"
    echo ""
    echo "  --static  Run only documentation, translation syntax, Unicode scan, Python/shell syntax, runner/release/mirror/RC/libwebrtc/builder-digest self-tests, runtime matrix self-test, package metadata and Flatpak manifest checks"
    echo "  --meson   Run the strict build and all Meson-registered tests only"
    echo "  --db      Run only DB maintenance tests"
    echo "  --self-test  Validate this runner's argument handling only"
    echo "  --help    Show this help"
    echo ""
    echo "Without arguments: run static checks, strict build, Meson tests, and DB tests"
}

run_self_test() {
    local output rc

    output="$("$0" --help)"
    if ! grep -qF "runner/release/mirror/RC/libwebrtc/builder-digest self-tests" <<< "$output"; then
        echo "Self-test failed: --help does not mention release/RC/libwebrtc/builder-digest self-tests" >&2
        return 1
    fi
    if ! grep -qF "runtime matrix self-test" <<< "$output"; then
        echo "Self-test failed: --help does not mention runtime matrix self-test" >&2
        return 1
    fi
    if ! grep -qF "Flatpak manifest checks" <<< "$output"; then
        echo "Self-test failed: --help does not mention Flatpak manifest checks" >&2
        return 1
    fi

    "$0" -h >/dev/null

    if output="$("$0" --unknown 2>&1)"; then
        echo "Self-test failed: accepted an unknown argument" >&2
        return 1
    else
        rc=$?
    fi
    if [[ "$rc" -ne 2 ]] || ! grep -qF "Unknown argument: --unknown" <<< "$output"; then
        echo "Self-test failed: unexpected unknown-argument handling" >&2
        return 1
    fi

    if output="$("$0" --static --db 2>&1)"; then
        echo "Self-test failed: accepted multiple mode arguments" >&2
        return 1
    else
        rc=$?
    fi
    if [[ "$rc" -ne 2 ]] || ! grep -qF "Unknown arguments: --static --db" <<< "$output"; then
        echo "Self-test failed: unexpected multi-argument handling" >&2
        return 1
    fi

    echo "Self-test OK"
}

# Counters
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
SUITE_RESULTS=()

run_suite() {
    local name="$1"
    local cmd="$2"
    local pass=0
    local fail=0

    echo ""
    echo -e "${BOLD}>>> $name${NC}"
    echo "    Command: $cmd"
    echo ""

    if eval "$cmd"; then
        pass=1
        SUITE_RESULTS+=("${GREEN}PASS${NC}  $name")
    else
        fail=1
        SUITE_RESULTS+=("${RED}FAIL${NC}  $name")
    fi

    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))
}

run_static_tests() {
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD} Static Checks${NC}"
    echo -e "${BOLD}============================================${NC}"

    run_suite "Documentation link checker self-test" \
        "$PROJECT_DIR/scripts/check-doc-links.py --self-test"

    run_suite "Documentation link check" \
        "$PROJECT_DIR/scripts/check-doc-links.py"

    run_suite "Translation syntax checker self-test" \
        "$PROJECT_DIR/scripts/check_translations.py --self-test"

    run_suite "Translation syntax check" \
        "$PROJECT_DIR/scripts/check_translations.py --syntax-only"

    run_suite "Hidden Unicode scanner self-test" \
        "$PROJECT_DIR/scripts/scan_unicode.py --self-test"

    run_suite "Hidden Unicode scan" \
        "$PROJECT_DIR/scripts/scan_unicode.py"

    run_suite "Python syntax checker self-test" \
        "$PROJECT_DIR/scripts/check-python-syntax.py --self-test"

    run_suite "Python syntax check" \
        "$PROJECT_DIR/scripts/check-python-syntax.py"

    run_suite "Shell script syntax checker self-test" \
        "$PROJECT_DIR/scripts/check-shell-syntax.sh --self-test"

    run_suite "Shell script syntax check" \
        "$PROJECT_DIR/scripts/check-shell-syntax.sh"

    run_suite "DinoX test runner self-test" \
        "$PROJECT_DIR/scripts/run_all_tests.sh --self-test"

    run_suite "Release script self-test" \
        "$PROJECT_DIR/scripts/release.sh --self-test"

    run_suite "Release helper self-test" \
        "$PROJECT_DIR/scripts/release_helper.sh --self-test"

    run_suite "Forgejo release helper self-test" \
        "$PROJECT_DIR/scripts/forgejo-release.sh --self-test"

    run_suite "Forgejo release preparation self-test" \
        "$PROJECT_DIR/scripts/prepare-forgejo-release.sh --self-test"

    run_suite "Forgejo release candidate verifier self-test" \
        "$PROJECT_DIR/scripts/verify-release-candidate.sh --self-test"

    run_suite "Linux package-builder digest updater self-test" \
        "$PROJECT_DIR/scripts/update-linux-package-builder-digest.sh --self-test"

    run_suite "Linux package-builder digest pin invariants" \
        "$PROJECT_DIR/scripts/update-linux-package-builder-digest.sh --check-current"

    run_suite "AppImage runtime mirror self-test" \
        "$PROJECT_DIR/scripts/mirror-appimage-runtimes.sh --self-test"

    run_suite "libwebrtc wrapper configure helper self-test" \
        "$PROJECT_DIR/scripts/configure-libwebrtc-wrapper-build.sh --self-test"

    run_suite "libwebrtc runtime provenance self-test" \
        "$PROJECT_DIR/scripts/libwebrtc-runtime-provenance.py self-test"

    run_suite "Linux source dependency helper self-test" \
        "$PROJECT_DIR/scripts/prepare-linux-source-build-deps.sh --self-test"

    run_suite "Windows source dependency helper self-test" \
        "$PROJECT_DIR/scripts/prepare-windows-build-deps.sh --self-test"

    run_suite "Windows distribution builder self-test" \
        "$PROJECT_DIR/scripts/build-windows-dist.sh --self-test"

    run_suite "Package license owner self-test" \
        "$PROJECT_DIR/scripts/stage-package-licenses.sh --self-test"

    run_suite "Runtime matrix self-test" \
        "$PROJECT_DIR/scripts/package-runtime-matrix.sh self-test"

    run_suite "Package metadata check" \
        "$PROJECT_DIR/scripts/package-runtime-matrix.sh metadata"

    if [[ "${DINOX_SKIP_FLATPAK_MANIFEST_STATIC:-0}" == "1" ]]; then
        echo ""
        echo -e "${YELLOW}SKIP${NC}: Flatpak manifest check disabled for this static-check context"
        TOTAL_SKIP=$((TOTAL_SKIP + 1))
        SUITE_RESULTS+=("${YELLOW}SKIP${NC}  Flatpak manifest check (package-specific job)")
    else
        run_suite "Flatpak manifest check" \
            "$PROJECT_DIR/scripts/package-runtime-matrix.sh flatpak-manifest im.dinox.dinox.json"
    fi
}

run_google_webrtc_meson_tests() (
    local test_rc=0
    local restore_rc=0

    restore_production_profile() {
        meson setup --reconfigure build -Dgoogle-libwebrtc-tests=false \
            >/dev/null 2>&1 || true
    }
    trap restore_production_profile EXIT

    if meson setup --reconfigure build -Dgoogle-libwebrtc-tests=true; then
        if "$PROJECT_DIR/scripts/build.sh" --strict; then
            if meson test -C build --print-errorlogs --timeout-multiplier 10 --num-processes 1; then
                :
            else
                test_rc=$?
            fi
        else
            test_rc=$?
        fi
    else
        test_rc=$?
    fi

    if meson setup --reconfigure build -Dgoogle-libwebrtc-tests=false; then
        trap - EXIT
    else
        restore_rc=$?
    fi

    if [[ "$test_rc" -ne 0 ]]; then
        return "$test_rc"
    fi
    return "$restore_rc"
)

run_meson_tests() {
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD} Meson Tests${NC}"
    echo -e "${BOLD}============================================${NC}"

    # Always recover the production graph first. An interrupted earlier test
    # run must not make the initial strict build inherit test-only targets.
    if ! meson setup --reconfigure build -Dgoogle-libwebrtc-tests=false; then
        echo -e "${RED}PRODUCTION CONFIGURATION FAILED${NC}"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        SUITE_RESULTS+=("${RED}FAIL${NC}  Meson production configuration")
        return 0
    fi

    # Build the production profile first with the project wrapper so its
    # compiler warnings remain an independent package gate.
    if ! "$PROJECT_DIR/scripts/build.sh" --strict; then
        echo -e "${RED}BUILD FAILED${NC}"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        SUITE_RESULTS+=("${RED}FAIL${NC}  Meson build")
        # Keep control flow in this runner so the final summary is still printed.
        return 0
    fi

    # The test profile gets its own strict build. The subshell always restores
    # the production graph, including when compilation or a test aborts.
    run_suite "Strict test build and all Meson-registered tests" \
        "run_google_webrtc_meson_tests"
}

run_db_tests() {
    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD} DB Maintenance Tests${NC}"
    echo -e "${BOLD}============================================${NC}"

    if command -v sqlcipher &>/dev/null; then
        if [[ -x "$PROJECT_DIR/scripts/test_db_maintenance.sh" ]]; then
            run_suite "DB CLI tests" \
                "$PROJECT_DIR/scripts/test_db_maintenance.sh"
        else
            echo -e "${YELLOW}SKIP${NC}: scripts/test_db_maintenance.sh not found or not executable"
            TOTAL_SKIP=$((TOTAL_SKIP + 1))
            SUITE_RESULTS+=("${YELLOW}SKIP${NC}  DB CLI tests (script not executable)")
        fi
    else
        echo -e "${YELLOW}SKIP${NC}: sqlcipher not in PATH (required for DB CLI tests)"
        TOTAL_SKIP=$((TOTAL_SKIP + 1))
        SUITE_RESULTS+=("${YELLOW}SKIP${NC}  DB CLI tests (sqlcipher not in PATH)")
    fi

    if [[ -x "$PROJECT_DIR/scripts/run_db_integration_tests.sh" ]]; then
        run_suite "DB Integration tests" \
            "$PROJECT_DIR/scripts/run_db_integration_tests.sh"
    else
        echo -e "${YELLOW}SKIP${NC}: scripts/run_db_integration_tests.sh not found or not executable"
        TOTAL_SKIP=$((TOTAL_SKIP + 1))
        SUITE_RESULTS+=("${YELLOW}SKIP${NC}  DB Integration tests (script not executable)")
    fi
}

# Parse arguments
RUN_MESON=true
RUN_DB=true
RUN_STATIC=true

if [[ $# -gt 1 ]]; then
    echo -e "${RED}Unknown arguments: $*${NC}" >&2
    usage >&2
    exit 2
elif [[ "${1:-}" == "--meson" ]]; then
    RUN_DB=false
    RUN_STATIC=false
elif [[ "${1:-}" == "--db" ]]; then
    RUN_MESON=false
    RUN_STATIC=false
elif [[ "${1:-}" == "--static" ]]; then
    RUN_MESON=false
    RUN_DB=false
elif [[ "${1:-}" == "--self-test" ]]; then
    run_self_test
    exit 0
elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
elif [[ $# -gt 0 ]]; then
    echo -e "${RED}Unknown argument: $1${NC}" >&2
    usage >&2
    exit 2
fi

echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD} DinoX -- Complete Test Run${NC}"
echo -e "${BOLD}==========================================${NC}"
echo "  Date:    $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Branch:  $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
echo "  Commit:  $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

if $RUN_STATIC; then run_static_tests; fi
if $RUN_MESON; then run_meson_tests; fi
if $RUN_DB; then run_db_tests; fi

# Summary
echo ""
echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD} Summary${NC}"
echo -e "${BOLD}==========================================${NC}"
for result in "${SUITE_RESULTS[@]}"; do
    echo -e "  $result"
done
echo ""
echo -e "  Pass: ${GREEN}${TOTAL_PASS}${NC}  Fail: ${RED}${TOTAL_FAIL}${NC}  Skip: ${YELLOW}${TOTAL_SKIP}${NC}"

if [[ $TOTAL_FAIL -gt 0 ]]; then
    echo ""
    echo -e "${RED}SOME TESTS FAILED${NC}"
    exit 1
else
    echo ""
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
fi
