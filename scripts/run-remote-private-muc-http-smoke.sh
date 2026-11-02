#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
TEST_PATH="/RemotePrivateMucHttpSmoke/private_muc_unencrypted_http_send_receive_env"
MODE="run"

usage() {
    cat <<EOF
Usage: $0 [--preflight] [--build-dir DIR]

Runs the env-backed remote private-MUC DinoX-to-DinoX HTTP file-send smoke.

Required environment:
  DINOX_REMOTE_MUC_FILE_SENDER_JID
  DINOX_REMOTE_MUC_FILE_SENDER_PASSWORD
  DINOX_REMOTE_MUC_FILE_RECEIVER_JID
  DINOX_REMOTE_MUC_FILE_RECEIVER_PASSWORD
  DINOX_REMOTE_MUC_SERVICE

Optional environment:
  DINOX_REMOTE_MUC_HOST
  DINOX_REMOTE_MUC_PORT
  DINOX_REMOTE_MUC_FILE_SENDER_NICK
  DINOX_REMOTE_MUC_FILE_RECEIVER_NICK
  DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID
  DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_PASSWORD
  DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_NICK
  DINOX_REMOTE_MUC_BOOTSTRAP_ROOM_PREFIX
  DINOX_REMOTE_MUC_TIMEOUT_SECONDS
  DINOX_REMOTE_MUC_FILE_NAME
  DINOX_REMOTE_MUC_FILE_PAYLOAD_TEXT

Options:
  --preflight       Validate required environment and local build target only.
  --build-dir       Use a non-default Meson build directory.
  --help            Show this help.

The runner never prints passwords, full JIDs, generated room JIDs, payload text
or upload/download URLs. The smoke uploads one tiny synthetic file to the
configured server; server-side HTTP upload retention is controlled by the server.
EOF
}

error() {
    echo "ERROR: $*" >&2
}

is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

parse_uint10() {
    printf '%d' "$((10#$1))"
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

validate_domain_jid() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
        error "$name must be a domain JID such as conference.example.test"
        return 1
    fi
}

validate_account_jid() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[^[:space:]@/]+@[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
        error "$name must be a bare account JID such as user@example.test"
        return 1
    fi
}

validate_payload_name() {
    local name="$1"
    local value="$2"
    if [[ -z "$value" || "$value" == "." || "$value" == ".." || "$value" == */* || "$value" == *\\* ]]; then
        error "$name must be a simple file name"
        return 1
    fi
}

validate_env() {
    MISSING_ENV=()
    require_env DINOX_REMOTE_MUC_FILE_SENDER_JID
    require_env DINOX_REMOTE_MUC_FILE_SENDER_PASSWORD
    require_env DINOX_REMOTE_MUC_FILE_RECEIVER_JID
    require_env DINOX_REMOTE_MUC_FILE_RECEIVER_PASSWORD
    require_env DINOX_REMOTE_MUC_SERVICE

    if [[ "${#MISSING_ENV[@]}" -gt 0 ]]; then
        error "missing required environment:"
        printf '  %s\n' "${MISSING_ENV[@]}" >&2
        return 1
    fi

    validate_no_newline DINOX_REMOTE_MUC_FILE_SENDER_JID "$DINOX_REMOTE_MUC_FILE_SENDER_JID"
    validate_no_newline DINOX_REMOTE_MUC_FILE_SENDER_PASSWORD "$DINOX_REMOTE_MUC_FILE_SENDER_PASSWORD"
    validate_no_newline DINOX_REMOTE_MUC_FILE_RECEIVER_JID "$DINOX_REMOTE_MUC_FILE_RECEIVER_JID"
    validate_no_newline DINOX_REMOTE_MUC_FILE_RECEIVER_PASSWORD "$DINOX_REMOTE_MUC_FILE_RECEIVER_PASSWORD"
    validate_no_newline DINOX_REMOTE_MUC_SERVICE "$DINOX_REMOTE_MUC_SERVICE"
    validate_account_jid DINOX_REMOTE_MUC_FILE_SENDER_JID "$DINOX_REMOTE_MUC_FILE_SENDER_JID"
    validate_account_jid DINOX_REMOTE_MUC_FILE_RECEIVER_JID "$DINOX_REMOTE_MUC_FILE_RECEIVER_JID"
    validate_domain_jid DINOX_REMOTE_MUC_SERVICE "$DINOX_REMOTE_MUC_SERVICE"

    if [[ "$DINOX_REMOTE_MUC_FILE_SENDER_JID" == "$DINOX_REMOTE_MUC_FILE_RECEIVER_JID" ]]; then
        error "sender and receiver accounts must be distinct"
        return 1
    fi

    if [[ -n "${DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID:-}" || -n "${DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_PASSWORD:-}" ]]; then
        if [[ -z "${DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID:-}" || -z "${DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_PASSWORD:-}" ]]; then
            error "DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID and DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_PASSWORD must be set together"
            return 1
        fi
        validate_no_newline DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID "$DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID"
        validate_no_newline DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_PASSWORD "$DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_PASSWORD"
        validate_account_jid DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID "$DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID"
        if [[ "$DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID" == "$DINOX_REMOTE_MUC_FILE_SENDER_JID" ||
              "$DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID" == "$DINOX_REMOTE_MUC_FILE_RECEIVER_JID" ]]; then
            error "sender, receiver and extra receiver accounts must be distinct"
            return 1
        fi
    fi

    for name in \
        DINOX_REMOTE_MUC_HOST \
        DINOX_REMOTE_MUC_FILE_SENDER_NICK \
        DINOX_REMOTE_MUC_FILE_RECEIVER_NICK \
        DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_NICK \
        DINOX_REMOTE_MUC_BOOTSTRAP_ROOM_PREFIX \
        DINOX_REMOTE_MUC_FILE_PAYLOAD_TEXT
    do
        if [[ -n "${!name:-}" ]]; then
            validate_no_newline "$name" "${!name}"
        fi
    done

    if [[ -n "${DINOX_REMOTE_MUC_FILE_NAME:-}" ]]; then
        validate_no_newline DINOX_REMOTE_MUC_FILE_NAME "$DINOX_REMOTE_MUC_FILE_NAME"
        validate_payload_name DINOX_REMOTE_MUC_FILE_NAME "$DINOX_REMOTE_MUC_FILE_NAME"
    fi

    if [[ -n "${DINOX_REMOTE_MUC_PORT:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_MUC_PORT"; then
            error "DINOX_REMOTE_MUC_PORT must be an integer between 1 and 65535"
            return 1
        fi
        local port
        port="$(parse_uint10 "$DINOX_REMOTE_MUC_PORT")"
        if ((port < 1 || port > 65535)); then
            error "DINOX_REMOTE_MUC_PORT must be an integer between 1 and 65535"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_MUC_TIMEOUT_SECONDS:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_MUC_TIMEOUT_SECONDS"; then
            error "DINOX_REMOTE_MUC_TIMEOUT_SECONDS must be an integer between 5 and 600"
            return 1
        fi
        local timeout
        timeout="$(parse_uint10 "$DINOX_REMOTE_MUC_TIMEOUT_SECONDS")"
        if ((timeout < 5 || timeout > 600)); then
            error "DINOX_REMOTE_MUC_TIMEOUT_SECONDS must be an integer between 5 and 600"
            return 1
        fi
    fi
}

validate_build_dir() {
    if [[ ! -d "$BUILD_DIR" ]]; then
        error "build directory not found: $BUILD_DIR"
        error "run: meson setup build"
        return 1
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
        "$BUILD_DIR/plugins/http-files"
        "$BUILD_DIR/plugins/omemo"
        "$BUILD_DIR/plugins/openpgp"
        "$BUILD_DIR/plugins/ice"
    )

    for dir in "${runtime_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            path_value="$dir${path_value:+:$path_value}"
            ld_library_path_value="$dir${ld_library_path_value:+:$ld_library_path_value}"
        fi
    done
    env PATH="$path_value" LD_LIBRARY_PATH="$ld_library_path_value" "$@"
}

compile_test_target() {
    env \
        -u DINOX_REMOTE_MUC_HTTP_FILE_SMOKE \
        -u DINOX_REMOTE_MUC_FILE_SENDER_JID \
        -u DINOX_REMOTE_MUC_FILE_SENDER_PASSWORD \
        -u DINOX_REMOTE_MUC_FILE_RECEIVER_JID \
        -u DINOX_REMOTE_MUC_FILE_RECEIVER_PASSWORD \
        -u DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID \
        -u DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_PASSWORD \
        -u DINOX_REMOTE_MUC_SERVICE \
        -u DINOX_REMOTE_MUC_HOST \
        -u DINOX_REMOTE_MUC_PORT \
        -u DINOX_REMOTE_MUC_FILE_SENDER_NICK \
        -u DINOX_REMOTE_MUC_FILE_RECEIVER_NICK \
        -u DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_NICK \
        -u DINOX_REMOTE_MUC_BOOTSTRAP_ROOM_PREFIX \
        -u DINOX_REMOTE_MUC_TIMEOUT_SECONDS \
        -u DINOX_REMOTE_MUC_FILE_NAME \
        -u DINOX_REMOTE_MUC_FILE_PAYLOAD_TEXT \
        meson compile -C "$BUILD_DIR" plugins/http-files/http-files-test
}

sanitize_log() {
    local log_file="$1"
    perl -0pe '
        for my $name (qw(
            DINOX_REMOTE_MUC_FILE_SENDER_JID
            DINOX_REMOTE_MUC_FILE_SENDER_PASSWORD
            DINOX_REMOTE_MUC_FILE_RECEIVER_JID
            DINOX_REMOTE_MUC_FILE_RECEIVER_PASSWORD
            DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_JID
            DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_PASSWORD
            DINOX_REMOTE_MUC_SERVICE
            DINOX_REMOTE_MUC_HOST
            DINOX_REMOTE_MUC_FILE_SENDER_NICK
            DINOX_REMOTE_MUC_FILE_RECEIVER_NICK
            DINOX_REMOTE_MUC_FILE_EXTRA_RECEIVER_NICK
            DINOX_REMOTE_MUC_BOOTSTRAP_ROOM_PREFIX
            DINOX_REMOTE_MUC_FILE_NAME
            DINOX_REMOTE_MUC_FILE_PAYLOAD_TEXT
        )) {
            my $value = $ENV{$name};
            next if !defined($value) || $value eq "";
            s/\Q$value\E/<$name>/g;
        }
        s{https?://[^\s<>"]+}{<remote-http-url>}g;
        s/dinox-remote-muc-http-smoke-[0-9a-f-]+\@[A-Za-z0-9.-]+/<generated-muc-room>/g;
        s/dinox-remote-muc-http-smoke-[0-9a-f-]+/<generated-temp-name>/g;
    ' "$log_file"
}

run_smoke() {
    local test_binary="$BUILD_DIR/plugins/http-files/http-files-test"
    if [[ ! -x "$test_binary" ]]; then
        error "test binary not found: $test_binary"
        return 1
    fi

    local log_file
    local status=0
    log_file="$(mktemp "${TMPDIR:-/tmp}/dinox-remote-private-muc-http-smoke.XXXXXX.log")"

    run_with_build_runtime_path DINOX_REMOTE_MUC_HTTP_FILE_SMOKE=1 "$test_binary" -p "$TEST_PATH" > "$log_file" 2>&1 || status="$?"

    if ((status != 0)); then
        error "remote private-MUC HTTP file smoke failed"
        sanitize_log "$log_file" >&2
        rm -f "$log_file"
        return "$status"
    fi

    rm -f "$log_file"
    echo "remote-private-muc-http-file-ok"
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --preflight)
            MODE="preflight"
            shift
            ;;
        --build-dir)
            if [[ "$#" -lt 2 ]]; then
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
validate_build_dir
compile_test_target

if [[ "$MODE" = "preflight" ]]; then
    echo "Remote private-MUC HTTP file smoke preflight OK"
    echo "Focused test: $TEST_PATH"
    echo "Build dir: $BUILD_DIR"
    exit 0
fi

run_smoke
