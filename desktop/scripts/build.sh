#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# DinoX build wrapper — captures all compiler warnings and,
# with --strict, fails the build if any warning appears.
#
# Usage:  ./scripts/build.sh [--build-dir DIR] [--prepare-tor] [--clean] [--strict] [--run]
#
#   --build-dir DIR  configured Meson tree (relative to the caller or absolute)
#   --clean    clean and rebuild; keep the Meson configuration
#   --strict   treat warnings as errors (fail on ANY warning)
#   --run      launch DinoX after successful build
#   --prepare-tor explicitly prepare the pinned private Linux Tor helpers
#
# Output:
#   build_log.txt           full build output
#   build_warnings.txt      extracted warnings only
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
LOG_FILE="$PROJECT_DIR/build_log.txt"
WARN_FILE="$PROJECT_DIR/build_warnings.txt"

NINJA_ARGS=()
if [ -n "${DINOX_BUILD_JOBS:-${DINOX_CI_JOBS:-}}" ]; then
    DINOX_EFFECTIVE_JOBS="${DINOX_BUILD_JOBS:-${DINOX_CI_JOBS:-}}"
    if ! [[ "$DINOX_EFFECTIVE_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        echo "Invalid DINOX build job limit: $DINOX_EFFECTIVE_JOBS" >&2
        exit 2
    fi
    NINJA_ARGS=(-j "$DINOX_EFFECTIVE_JOBS")
fi

# ANSI colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DO_CLEAN=false
STRICT=false
DO_RUN=false
PREPARE_TOR=false

usage() {
    echo "Usage: $0 [--build-dir DIR] [--prepare-tor] [--clean] [--strict] [--run]"
    echo "  --build-dir DIR  configured Meson tree (default: project/build; relative to caller)"
    echo "  --clean    clean and rebuild; keep the Meson configuration"
    echo "  --strict   fail on any warning"
    echo "  --run      launch DinoX with broad debug output after build"
    echo "  --prepare-tor explicitly prepare private Linux Tor/Lyrebird; may download pinned sources if missing"
}

if [ "$#" -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
    usage
    exit 0
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --build-dir)
            if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "--build-dir requires a configured Meson directory" >&2
                exit 2
            fi
            case "$2" in
                /*) BUILD_DIR="$2" ;;
                *) BUILD_DIR="$PWD/$2" ;;
            esac
            shift
            ;;
        --clean)  DO_CLEAN=true ;;
        --strict) STRICT=true ;;
        --run)    DO_RUN=true ;;
        --prepare-tor) PREPARE_TOR=true ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    echo "DinoX is not configured in $BUILD_DIR." >&2
    echo "Follow docs/internal/BUILD.md#linux-source-build and run Meson setup first." >&2
    exit 1
fi

if $PREPARE_TOR; then
    bash "$SCRIPT_DIR/prepare-linux-tor-runtime.sh"
fi

cd "$BUILD_DIR"

echo -e "${CYAN}━━━ DinoX Build ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Project:  $PROJECT_DIR"
echo -e "  Build:    $BUILD_DIR"
echo -e "  Strict:   $STRICT"
if [ "${#NINJA_ARGS[@]}" -gt 0 ]; then
    echo -e "  Jobs:     ${NINJA_ARGS[1]}"
fi
echo ""

# ── Clean ─────────────────────────────────────────────────────
if $DO_CLEAN; then
    echo -e "${YELLOW}▸ Cleaning build artifacts...${NC}"
    ninja clean 2>&1 | tail -1
    echo ""
fi

# ── Build ─────────────────────────────────────────────────────
echo -e "${CYAN}▸ Building...${NC}"
BUILD_START=$(date +%s)

# Capture full output, show progress, save to log
# Temporarily disable -e so a build failure reaches the error handler below
set +e
ninja "${NINJA_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
BUILD_EXIT=${PIPESTATUS[0]}
set -e

BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))

echo ""

if [ $BUILD_EXIT -ne 0 ]; then
    echo -e "${RED}━━━ BUILD FAILED ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Full log: $LOG_FILE"
    exit 1
fi

# ── Extract warnings ──────────────────────────────────────────
# Share the whole-session parser so C++, headers and compiler-driver warnings
# also fail --strict. A warning-report failure must not become a clean result.
python3 "$SCRIPT_DIR/compiler-warning-report.py" "$LOG_FILE" --output "$WARN_FILE"

WARN_COUNT=$(wc -l < "$WARN_FILE" | tr -d ' ')

echo -e "${GREEN}━━━ BUILD SUCCEEDED ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Time:     ${BUILD_TIME}s"
echo -e "  Log:      $LOG_FILE"

# ── Warning report ────────────────────────────────────────────
if [ "$WARN_COUNT" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}━━━ ⚠  $WARN_COUNT COMPILER WARNING(S) ━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    cat "$WARN_FILE" | while IFS= read -r line; do
        echo -e "  ${YELLOW}⚠${NC}  $line"
    done
    echo ""
    echo -e "  Saved to: $WARN_FILE"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if $STRICT; then
        echo ""
        echo -e "${RED}  STRICT MODE: Failing build due to $WARN_COUNT warning(s).${NC}"
        echo -e "${RED}  Fix warnings or build without --strict.${NC}"
        exit 1
    fi
else
    echo -e "  Warnings in this invocation: ${GREEN}0${NC}"
    echo "  Only files compiled by this invocation were checked."
fi

echo ""

# ── Run ───────────────────────────────────────────────────────
if $DO_RUN; then
    echo -e "${CYAN}▸ Launching DinoX with G_MESSAGES_DEBUG...${NC}"
    echo ""
    # Enable ALL debug output so GTK warnings are visible
    export G_MESSAGES_DEBUG=all
    # Make GTK warnings fatal so they crash instead of hiding
    # Uncomment the next line to make warnings fatal:
    # export G_DEBUG=fatal-warnings
    exec "$BUILD_DIR/main/dinox"
fi
