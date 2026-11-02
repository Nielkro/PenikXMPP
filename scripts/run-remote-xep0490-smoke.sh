#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
TEST_PATH="/RemoteXep0490Smoke/regular_pep_same_account_env"
MODE="run"

usage() {
    cat <<EOF
Usage: $0 [--preflight] [--build-dir DIR]

Runs the opt-in XEP-0490 regular-PEP smoke with two DinoX resources of the
same account.

Required environment:
  DINOX_REMOTE_XEP0490_JID
  DINOX_REMOTE_XEP0490_PASSWORD
  DINOX_REMOTE_XEP0490_CONTACT
  DINOX_REMOTE_XEP0490_ROOM

Optional environment:
  DINOX_REMOTE_XEP0490_HOST
  DINOX_REMOTE_XEP0490_PORT
  DINOX_REMOTE_XEP0490_TIMEOUT_SECONDS
  DINOX_REMOTE_XEP0490_EXPECTED_CHAT
  DINOX_REMOTE_XEP0490_EXPECTED_ID
  DINOX_REMOTE_XEP0490_EXPECTED_BY

The runner never prints credentials or unredacted test JIDs.
EOF
}

error() {
    echo "ERROR: $*" >&2
}

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        MISSING_ENV+=("$name")
    fi
}

validate_no_newline() {
    local name="$1"
    local value="$2"
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        error "$name must not contain newline characters"
        return 1
    fi
}

validate_bare_jid() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[^[:space:]@/]+@[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
        error "$name must be a bare JID"
        return 1
    fi
}

validate_chat_jid() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[^[:space:]@/]+@[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+(/[^[:cntrl:]]+)?$ ]]; then
        error "$name must be a bare or full JID"
        return 1
    fi
}

validate_env() {
    MISSING_ENV=()
    require_env DINOX_REMOTE_XEP0490_JID
    require_env DINOX_REMOTE_XEP0490_PASSWORD
    require_env DINOX_REMOTE_XEP0490_CONTACT
    require_env DINOX_REMOTE_XEP0490_ROOM
    if ((${#MISSING_ENV[@]} > 0)); then
        error "missing required environment:"
        printf '  %s\n' "${MISSING_ENV[@]}" >&2
        return 1
    fi

    local name
    for name in \
        DINOX_REMOTE_XEP0490_JID \
        DINOX_REMOTE_XEP0490_PASSWORD \
        DINOX_REMOTE_XEP0490_CONTACT \
        DINOX_REMOTE_XEP0490_ROOM \
        DINOX_REMOTE_XEP0490_HOST \
        DINOX_REMOTE_XEP0490_EXPECTED_CHAT \
        DINOX_REMOTE_XEP0490_EXPECTED_ID \
        DINOX_REMOTE_XEP0490_EXPECTED_BY; do
        validate_no_newline "$name" "${!name:-}"
    done
    validate_bare_jid DINOX_REMOTE_XEP0490_JID \
        "$DINOX_REMOTE_XEP0490_JID"
    validate_bare_jid DINOX_REMOTE_XEP0490_CONTACT \
        "$DINOX_REMOTE_XEP0490_CONTACT"
    validate_bare_jid DINOX_REMOTE_XEP0490_ROOM \
        "$DINOX_REMOTE_XEP0490_ROOM"

    local expected_count=0
    for name in \
        DINOX_REMOTE_XEP0490_EXPECTED_CHAT \
        DINOX_REMOTE_XEP0490_EXPECTED_ID \
        DINOX_REMOTE_XEP0490_EXPECTED_BY; do
        if [[ -n "${!name:-}" ]]; then
            expected_count=$((expected_count + 1))
        fi
    done
    if ((expected_count != 0 && expected_count != 3)); then
        error "EXPECTED_CHAT, EXPECTED_ID, and EXPECTED_BY must be set together"
        return 1
    fi
    if ((expected_count == 3)); then
        validate_chat_jid DINOX_REMOTE_XEP0490_EXPECTED_CHAT \
            "$DINOX_REMOTE_XEP0490_EXPECTED_CHAT"
        validate_bare_jid DINOX_REMOTE_XEP0490_EXPECTED_BY \
            "$DINOX_REMOTE_XEP0490_EXPECTED_BY"
    fi

    if [[ -n "${DINOX_REMOTE_XEP0490_PORT:-}" ]]; then
        if [[ ! "$DINOX_REMOTE_XEP0490_PORT" =~ ^[0-9]+$ ]] ||
                ((10#$DINOX_REMOTE_XEP0490_PORT < 1 ||
                    10#$DINOX_REMOTE_XEP0490_PORT > 65535)); then
            error "DINOX_REMOTE_XEP0490_PORT must be between 1 and 65535"
            return 1
        fi
    fi
    if [[ -n "${DINOX_REMOTE_XEP0490_TIMEOUT_SECONDS:-}" ]]; then
        if [[ ! "$DINOX_REMOTE_XEP0490_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] ||
                ((10#$DINOX_REMOTE_XEP0490_TIMEOUT_SECONDS < 5 ||
                    10#$DINOX_REMOTE_XEP0490_TIMEOUT_SECONDS > 600)); then
            error "DINOX_REMOTE_XEP0490_TIMEOUT_SECONDS must be between 5 and 600"
            return 1
        fi
    fi
}

run_with_build_runtime_path() {
    local dir
    local path_value="${PATH:-}"
    local ld_library_path_value="${LD_LIBRARY_PATH:-}"
    local -a runtime_dirs=(
        "$BUILD_DIR/libdino"
        "$BUILD_DIR/xmpp-vala"
        "$BUILD_DIR/qlite"
        "$BUILD_DIR/crypto-vala"
    )

    for dir in "${runtime_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            path_value="$dir${path_value:+:$path_value}"
            ld_library_path_value="$dir${ld_library_path_value:+:$ld_library_path_value}"
        fi
    done
    env PATH="$path_value" LD_LIBRARY_PATH="$ld_library_path_value" "$@"
}

sanitize_log() {
    local log_file="$1"
    perl -0pe '
        for my $name (qw(
            DINOX_REMOTE_XEP0490_JID
            DINOX_REMOTE_XEP0490_PASSWORD
            DINOX_REMOTE_XEP0490_CONTACT
            DINOX_REMOTE_XEP0490_ROOM
            DINOX_REMOTE_XEP0490_HOST
            DINOX_REMOTE_XEP0490_EXPECTED_CHAT
            DINOX_REMOTE_XEP0490_EXPECTED_ID
            DINOX_REMOTE_XEP0490_EXPECTED_BY
        )) {
            my $value = $ENV{$name};
            next if !defined($value) || $value eq "";
            s/\Q$value\E/<$name>/g;
        }
    ' "$log_file"
}

run_smoke() {
    local test_binary="$BUILD_DIR/libdino/libdino-test"
    local log_file
    local status=0
    local server_assist="unknown"
    log_file="$(mktemp "${TMPDIR:-/tmp}/dinox-remote-xep0490.XXXXXX.log")"

    run_with_build_runtime_path env DINOX_REMOTE_XEP0490_SMOKE=1 \
        "$test_binary" -p "$TEST_PATH" >"$log_file" 2>&1 || status="$?"
    if ((status != 0)); then
        error "remote XEP-0490 smoke failed"
        sanitize_log "$log_file" >&2
        rm -f "$log_file"
        return "$status"
    fi
    if grep -Fq "Account server-assist feature advertised: yes" "$log_file"; then
        server_assist="yes"
    elif grep -Fq "Account server-assist feature advertised: no" "$log_file"; then
        server_assist="no"
    fi
    rm -f "$log_file"
    echo "remote-xep0490-regular-pep-ok"
    echo "remote-xep0490-server-assist=$server_assist"
}

while (($# > 0)); do
    case "$1" in
        --preflight)
            MODE="preflight"
            shift
            ;;
        --build-dir)
            if (($# < 2)); then
                error "--build-dir requires a directory"
                exit 1
            fi
            BUILD_DIR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            error "unknown argument: $1"
            usage >&2
            exit 1
            ;;
    esac
done

validate_env
if [[ ! -d "$BUILD_DIR" ]]; then
    error "build directory not found: $BUILD_DIR"
    exit 1
fi

env -u DINOX_REMOTE_XEP0490_SMOKE \
    meson compile -C "$BUILD_DIR" libdino/libdino-test

if [[ "$MODE" == "preflight" ]]; then
    echo "Remote XEP-0490 smoke preflight OK"
    echo "Focused test: $TEST_PATH"
    echo "Build dir: $BUILD_DIR"
    exit 0
fi

run_smoke
