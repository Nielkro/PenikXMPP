#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
TEST_PATH="/RemoteForeignHttpUploadSmoke/incoming_go_sendxmpp_http_upload_env"
MAX_PAYLOAD_SIZE=4999999
MODE="run"
TEMP_DIR=""
RECEIVER_PID=""

usage() {
    cat <<EOF
Usage: $0 [--preflight] [--build-dir DIR]

Runs the env-backed remote foreign-client HTTP upload receive-store smoke.
The sender is go-sendxmpp using XEP-0363 HTTP Upload; DinoX is the receiver.

Required environment:
  DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_JID
  DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_PASSWORD
  DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_JID
  DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_PASSWORD

Optional environment:
  DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_HOST
  DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT
  DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_TIMEOUT_SECONDS
  DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_NAME
  DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PAYLOAD_FILE
  DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_GO_SENDXMPP

Options:
  --preflight          Validate required environment, go-sendxmpp and local build target only.
  --build-dir          Use a non-default Meson build directory.
  --help               Show this help.

The runner never prints passwords or raw environment values.
EOF
}

error() {
    echo "ERROR: $*" >&2
}

cleanup() {
    if [[ -n "${RECEIVER_PID:-}" ]] && kill -0 "$RECEIVER_PID" 2>/dev/null; then
        kill "$RECEIVER_PID" 2>/dev/null || true
        sleep 0.5
        if kill -0 "$RECEIVER_PID" 2>/dev/null; then
            kill -9 "$RECEIVER_PID" 2>/dev/null || true
        fi
        wait "$RECEIVER_PID" 2>/dev/null || true
    fi
    RECEIVER_PID=""

    if [[ -n "${TEMP_DIR:-}" ]]; then
        rm -rf "$TEMP_DIR"
        TEMP_DIR=""
    fi
}

is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

parse_uint10() {
    printf '%d' "$((10#$1))"
}

has_line_break() {
    case "$1" in
        *$'\n'*|*$'\r'*) return 0 ;;
        *) return 1 ;;
    esac
}

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        MISSING_ENV+=("$name")
    fi
}

validate_env() {
    MISSING_ENV=()
    require_env DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_JID
    require_env DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_PASSWORD
    require_env DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_JID
    require_env DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_PASSWORD

    if [[ "${#MISSING_ENV[@]}" -gt 0 ]]; then
        error "missing required environment:"
        printf '  %s\n' "${MISSING_ENV[@]}" >&2
        return 1
    fi

    if [[ "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_JID" == */* ||
            "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_JID" == */* ]]; then
        error "receiver and sender JIDs must be bare account JIDs"
        return 1
    fi
    for name in \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_JID \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_PASSWORD \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_JID \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_PASSWORD \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_HOST; do
        if [[ -n "${!name:-}" ]] && has_line_break "${!name}"; then
            error "$name must not contain CR/LF"
            return 1
        fi
    done
    if [[ "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_JID" == "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_JID" ]]; then
        error "receiver and sender JIDs must be distinct"
        return 1
    fi

    if [[ -n "${DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT"; then
            error "DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT must be an integer between 1 and 65535"
            return 1
        fi
        local port
        port="$(parse_uint10 "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT")"
        if ((port < 1 || port > 65535)); then
            error "DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT must be an integer between 1 and 65535"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_TIMEOUT_SECONDS:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_TIMEOUT_SECONDS"; then
            error "DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_TIMEOUT_SECONDS must be an integer between 5 and 600"
            return 1
        fi
        local timeout
        timeout="$(parse_uint10 "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_TIMEOUT_SECONDS")"
        if ((timeout < 5 || timeout > 600)); then
            error "DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_TIMEOUT_SECONDS must be an integer between 5 and 600"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PAYLOAD_FILE:-}" ]]; then
        if [[ ! -r "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PAYLOAD_FILE" ]]; then
            error "DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PAYLOAD_FILE must be readable"
            return 1
        fi
        local payload_size
        payload_size="$(wc -c < "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PAYLOAD_FILE" | tr -d '[:space:]')"
        if ! is_integer "$payload_size" || ((payload_size > MAX_PAYLOAD_SIZE)); then
            error "DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PAYLOAD_FILE must be at most $MAX_PAYLOAD_SIZE bytes"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_NAME:-}" ]]; then
        case "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_NAME" in
            */*|*$'\n'*|*$'\r'*|.|..)
                error "DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_NAME must be a basename without path separators"
                return 1
                ;;
        esac
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

validate_timeout_tool() {
    if ! command -v timeout >/dev/null 2>&1; then
        error "GNU timeout executable not found"
        return 1
    fi
}

go_sendxmpp_path() {
    local configured="${DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_GO_SENDXMPP:-go-sendxmpp}"
    if [[ "$configured" == */* ]]; then
        if [[ ! -x "$configured" ]]; then
            error "go-sendxmpp path is not executable: $configured"
            return 1
        fi
        printf '%s' "$configured"
        return 0
    fi
    if ! command -v "$configured" >/dev/null 2>&1; then
        error "go-sendxmpp executable not found; set DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_GO_SENDXMPP"
        return 1
    fi
    command -v "$configured"
}

validate_go_sendxmpp() {
    local binary
    binary="$(go_sendxmpp_path)"
    local help_output
    help_output="$("$binary" --help 2>&1 || true)"
    if ! grep -q -- '--http-upload' <<<"$help_output"; then
        error "go-sendxmpp does not advertise --http-upload support"
        return 1
    fi
}

compile_test_target() {
    env \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SMOKE \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_JID \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_PASSWORD \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_JID \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_PASSWORD \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_HOST \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_TIMEOUT_SECONDS \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_NAME \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PAYLOAD_FILE \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_GO_SENDXMPP \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_READY_FILE \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_EXPECTED_NAME \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_EXPECTED_SIZE \
        -u DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_EXPECTED_SHA256 \
        meson compile -C "$BUILD_DIR" plugins/http-files/http-files-test
}

wait_for_ready_file() {
    local ready_file="$1"
    local timeout_seconds="$2"
    local receiver_pid="$3"
    local iterations=$((timeout_seconds * 5))
    for ((i = 0; i < iterations; i++)); do
        if [[ -s "$ready_file" ]]; then
            return 0
        fi
        if ! kill -0 "$receiver_pid" 2>/dev/null; then
            return 2
        fi
        sleep 0.2
    done
    return 1
}

sanitize_log() {
    local log_file="$1"
    perl -0pe '
        for my $name (qw(
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_JID
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_PASSWORD
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_JID
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_PASSWORD
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_HOST
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_NAME
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PAYLOAD_FILE
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_GO_SENDXMPP
        )) {
            my $value = $ENV{$name};
            next if !defined($value) || $value eq "";
            s/\Q$value\E/<$name>/g;
        }
        s{https?://[^\s<>"]+}{<remote-http-url>}g;
        s{aesgcm://[^\s<>"]+}{<remote-aesgcm-url>}g;
        s{/(tmp|var/tmp)/[^\s<>"]*dinox-[^\s<>"]*}{<remote-smoke-temp-path>}g;
    ' "$log_file"
}

write_go_sendxmpp_config() {
    local config_file="$1"
    {
        printf 'username: %s\n' "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_JID"
        printf 'password: %s\n' "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_PASSWORD"
        if [[ -n "${DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_HOST:-}" ]]; then
            printf 'jserver: %s\n' "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_HOST"
        fi
        if [[ -n "${DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT:-}" ]]; then
            printf 'port: %s\n' "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT"
        fi
    } > "$config_file"
    chmod 600 "$config_file"
}

run_smoke() {
    local test_binary="$BUILD_DIR/plugins/http-files/http-files-test"
    if [[ ! -x "$test_binary" ]]; then
        error "test binary not found after compile: $test_binary"
        return 1
    fi

    local go_sendxmpp
    go_sendxmpp="$(go_sendxmpp_path)"
    local timeout_binary
    timeout_binary="$(command -v timeout)"
    local timeout="${DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_TIMEOUT_SECONDS:-90}"
    local receiver_timeout=$((timeout * 3))
    local payload_name="${DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_NAME:-dinox-foreign-http-upload-smoke.txt}"
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dinox-foreign-http-upload.XXXXXX")"
    local ready_file="$TEMP_DIR/receiver.ready"
    local receiver_log="$TEMP_DIR/receiver.log"
    local sender_log="$TEMP_DIR/go-sendxmpp.log"
    local config_file="$TEMP_DIR/go-sendxmpp.conf"
    local payload_file="${DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PAYLOAD_FILE:-}"

    trap cleanup EXIT INT TERM

    if [[ -z "$payload_file" ]]; then
        payload_file="$TEMP_DIR/$payload_name"
        printf 'DinoX remote foreign HTTP upload smoke payload\n' > "$payload_file"
    else
        payload_name="$(basename "$payload_file")"
    fi

    local expected_size
    local expected_sha256
    expected_size="$(wc -c < "$payload_file" | tr -d '[:space:]')"
    expected_sha256="$(sha256sum "$payload_file" | awk '{print $1}')"

    write_go_sendxmpp_config "$config_file"

    run_with_build_runtime_path \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SMOKE=1 \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_JID="$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_JID" \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_PASSWORD="$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_PASSWORD" \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_JID="$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_SENDER_JID" \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_EXPECTED_NAME="$payload_name" \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_EXPECTED_SIZE="$expected_size" \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_EXPECTED_SHA256="$expected_sha256" \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_HOST="${DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_HOST:-}" \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT="${DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_PORT:-}" \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_TIMEOUT_SECONDS="$timeout" \
            DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_READY_FILE="$ready_file" \
            "$timeout_binary" --kill-after=5s "${receiver_timeout}s" "$test_binary" -p "$TEST_PATH" > "$receiver_log" 2>&1 &
    RECEIVER_PID="$!"

    local ready_status=0
    wait_for_ready_file "$ready_file" "$timeout" "$RECEIVER_PID" || ready_status="$?"
    if [[ "$ready_status" -ne 0 ]]; then
        if [[ "$ready_status" -eq 2 ]]; then
            error "receiver smoke exited before it became ready"
        else
            error "receiver smoke did not become ready"
        fi
        sanitize_log "$receiver_log" >&2
        cleanup
        trap - EXIT INT TERM
        return 1
    fi

    if ! "$go_sendxmpp" -f "$config_file" --timeout "$timeout" --http-upload "$payload_file" \
            "$DINOX_REMOTE_FOREIGN_HTTP_UPLOAD_RECEIVER_JID" > "$sender_log" 2>&1; then
        error "go-sendxmpp HTTP upload sender failed"
        sanitize_log "$sender_log" >&2
        sanitize_log "$receiver_log" >&2
        cleanup
        trap - EXIT INT TERM
        return 1
    fi

    if ! wait "$RECEIVER_PID"; then
        error "receiver smoke failed after go-sendxmpp finished"
        sanitize_log "$sender_log" >&2
        sanitize_log "$receiver_log" >&2
        RECEIVER_PID=""
        cleanup
        trap - EXIT INT TERM
        return 1
    fi
    RECEIVER_PID=""

    echo "Remote foreign HTTP upload smoke passed"
    cleanup
    trap - EXIT INT TERM
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
                exit 2
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
            exit 2
            ;;
    esac
done

validate_env
validate_build_dir
validate_timeout_tool
validate_go_sendxmpp
compile_test_target

if [[ "$MODE" = "preflight" ]]; then
    echo "Remote foreign HTTP upload smoke preflight OK"
    echo "Focused test: $TEST_PATH plus go-sendxmpp --http-upload"
    exit 0
fi

run_smoke
