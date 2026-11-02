#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
PREPARED_ROOM_TEST_PATH="/RemotePrivateMucSmoke/private_muc_affiliation_snapshot_env"
BOOTSTRAP_TEST_PATH="/RemotePrivateMucSmoke/private_muc_bootstrap_affiliation_snapshot_env"

MODE="run"
SMOKE_KIND="bootstrap"

usage() {
    cat <<EOF
Usage: $0 [--preflight] [--bootstrap|--prepared-room] [--build-dir DIR]

Runs the env-backed remote private-MUC affiliation/member-list smoke test.

Required environment for --bootstrap:
  DINOX_REMOTE_MUC_JID
  DINOX_REMOTE_MUC_PASSWORD
  DINOX_REMOTE_MUC_SERVICE
  DINOX_REMOTE_MUC_MEMBER_JIDS

Required environment for --prepared-room:
  DINOX_REMOTE_MUC_JID
  DINOX_REMOTE_MUC_PASSWORD
  DINOX_REMOTE_MUC_ROOM
  DINOX_REMOTE_MUC_EXPECTED_MEMBERS

Optional environment:
  DINOX_REMOTE_MUC_HOST
  DINOX_REMOTE_MUC_PORT
  DINOX_REMOTE_MUC_NICK
  DINOX_REMOTE_MUC_ROOM_PASSWORD
  DINOX_REMOTE_MUC_JOIN=1
  DINOX_REMOTE_MUC_BOOTSTRAP_ROOM_PREFIX
  DINOX_REMOTE_MUC_TIMEOUT_SECONDS

Options:
  --preflight       Validate required environment and local build target only.
  --bootstrap       Create a generated members-only non-anonymous room, query it, then destroy it.
  --prepared-room   Query an externally prepared members-only non-anonymous room.
  --build-dir       Use a non-default Meson build directory.
  --help            Show this help.

The runner never prints passwords or full environment values.
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

validate_csv_jid_list() {
    local name="$1"
    local value="$2"
    local non_empty=0
    local part
    local -a parts

    IFS=',' read -r -a parts <<< "$value"
    for part in "${parts[@]}"; do
        part="${part#"${part%%[![:space:]]*}"}"
        part="${part%"${part##*[![:space:]]}"}"
        if [[ -n "$part" ]]; then
            validate_bare_jid "$name" "$part"
            non_empty=$((non_empty + 1))
        fi
    done

    if ((non_empty == 0)); then
        error "$name must contain at least one JID"
        return 1
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

validate_bare_jid() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[^[:space:]@/]+@[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
        error "$name must be a bare JID such as user@example.test"
        return 1
    fi
}

validate_account_jid() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[^[:space:]@/]+@[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+(/[^[:space:]]+)?$ ]]; then
        error "$name must be an account JID such as user@example.test"
        return 1
    fi
}

validate_env() {
    MISSING_ENV=()
    require_env DINOX_REMOTE_MUC_JID
    require_env DINOX_REMOTE_MUC_PASSWORD

    if [[ "$SMOKE_KIND" = "bootstrap" ]]; then
        require_env DINOX_REMOTE_MUC_SERVICE
        require_env DINOX_REMOTE_MUC_MEMBER_JIDS
    elif [[ "$SMOKE_KIND" = "prepared-room" ]]; then
        require_env DINOX_REMOTE_MUC_ROOM
        require_env DINOX_REMOTE_MUC_EXPECTED_MEMBERS
    else
        error "unsupported smoke kind: $SMOKE_KIND"
        return 1
    fi

    if [[ "${#MISSING_ENV[@]}" -gt 0 ]]; then
        error "missing required environment:"
        printf '  %s\n' "${MISSING_ENV[@]}" >&2
        return 1
    fi

    validate_no_newline DINOX_REMOTE_MUC_JID "$DINOX_REMOTE_MUC_JID"
    validate_no_newline DINOX_REMOTE_MUC_PASSWORD "$DINOX_REMOTE_MUC_PASSWORD"
    validate_account_jid DINOX_REMOTE_MUC_JID "$DINOX_REMOTE_MUC_JID"

    if [[ "$SMOKE_KIND" = "bootstrap" ]]; then
        validate_no_newline DINOX_REMOTE_MUC_SERVICE "$DINOX_REMOTE_MUC_SERVICE"
        validate_no_newline DINOX_REMOTE_MUC_MEMBER_JIDS "$DINOX_REMOTE_MUC_MEMBER_JIDS"
        validate_domain_jid DINOX_REMOTE_MUC_SERVICE "$DINOX_REMOTE_MUC_SERVICE"
        validate_csv_jid_list DINOX_REMOTE_MUC_MEMBER_JIDS "$DINOX_REMOTE_MUC_MEMBER_JIDS"
    else
        validate_no_newline DINOX_REMOTE_MUC_ROOM "$DINOX_REMOTE_MUC_ROOM"
        validate_no_newline DINOX_REMOTE_MUC_EXPECTED_MEMBERS "$DINOX_REMOTE_MUC_EXPECTED_MEMBERS"
        validate_bare_jid DINOX_REMOTE_MUC_ROOM "$DINOX_REMOTE_MUC_ROOM"
        validate_csv_jid_list DINOX_REMOTE_MUC_EXPECTED_MEMBERS "$DINOX_REMOTE_MUC_EXPECTED_MEMBERS"
    fi

    if [[ -n "${DINOX_REMOTE_MUC_HOST:-}" ]]; then
        validate_no_newline DINOX_REMOTE_MUC_HOST "$DINOX_REMOTE_MUC_HOST"
    fi
    if [[ -n "${DINOX_REMOTE_MUC_NICK:-}" ]]; then
        validate_no_newline DINOX_REMOTE_MUC_NICK "$DINOX_REMOTE_MUC_NICK"
    fi
    if [[ -n "${DINOX_REMOTE_MUC_ROOM_PASSWORD:-}" ]]; then
        validate_no_newline DINOX_REMOTE_MUC_ROOM_PASSWORD "$DINOX_REMOTE_MUC_ROOM_PASSWORD"
    fi
    if [[ -n "${DINOX_REMOTE_MUC_BOOTSTRAP_ROOM_PREFIX:-}" ]]; then
        validate_no_newline DINOX_REMOTE_MUC_BOOTSTRAP_ROOM_PREFIX "$DINOX_REMOTE_MUC_BOOTSTRAP_ROOM_PREFIX"
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

    if [[ -n "${DINOX_REMOTE_MUC_JOIN:-}" && "$DINOX_REMOTE_MUC_JOIN" != "0" && "$DINOX_REMOTE_MUC_JOIN" != "1" ]]; then
        error "DINOX_REMOTE_MUC_JOIN must be 0 or 1"
        return 1
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
        -u DINOX_REMOTE_MUC_SMOKE \
        -u DINOX_REMOTE_MUC_BOOTSTRAP \
        -u DINOX_REMOTE_MUC_JID \
        -u DINOX_REMOTE_MUC_PASSWORD \
        -u DINOX_REMOTE_MUC_ROOM \
        -u DINOX_REMOTE_MUC_EXPECTED_MEMBERS \
        -u DINOX_REMOTE_MUC_SERVICE \
        -u DINOX_REMOTE_MUC_MEMBER_JIDS \
        -u DINOX_REMOTE_MUC_HOST \
        -u DINOX_REMOTE_MUC_PORT \
        -u DINOX_REMOTE_MUC_NICK \
        -u DINOX_REMOTE_MUC_ROOM_PASSWORD \
        -u DINOX_REMOTE_MUC_JOIN \
        -u DINOX_REMOTE_MUC_BOOTSTRAP_ROOM_PREFIX \
        -u DINOX_REMOTE_MUC_TIMEOUT_SECONDS \
        meson compile -C "$BUILD_DIR" libdino/libdino-test
}

sanitize_log() {
    local log_file="$1"
    perl -0pe '
        for my $name (qw(
            DINOX_REMOTE_MUC_JID
            DINOX_REMOTE_MUC_PASSWORD
            DINOX_REMOTE_MUC_ROOM
            DINOX_REMOTE_MUC_EXPECTED_MEMBERS
            DINOX_REMOTE_MUC_SERVICE
            DINOX_REMOTE_MUC_MEMBER_JIDS
            DINOX_REMOTE_MUC_HOST
            DINOX_REMOTE_MUC_NICK
            DINOX_REMOTE_MUC_ROOM_PASSWORD
            DINOX_REMOTE_MUC_BOOTSTRAP_ROOM_PREFIX
        )) {
            my $value = $ENV{$name};
            next if !defined($value) || $value eq "";
            s/\Q$value\E/<$name>/g;
        }
        for my $name (qw(
            DINOX_REMOTE_MUC_EXPECTED_MEMBERS
            DINOX_REMOTE_MUC_MEMBER_JIDS
        )) {
            my $value = $ENV{$name};
            next if !defined($value) || $value eq "";
            for my $part (split /,/, $value) {
                $part =~ s/^\s+|\s+$//g;
                next if $part eq "";
                s/\Q$part\E/<$name:item>/g;
            }
        }
        s/dinox-remote-muc-smoke-[0-9a-f-]+\@[A-Za-z0-9.-]+/<generated-muc-room>/g;
    ' "$log_file"
}

run_smoke() {
    local test_binary="$BUILD_DIR/libdino/libdino-test"
    if [[ ! -x "$test_binary" ]]; then
        error "test binary not found: $test_binary"
        return 1
    fi

    local log_file
    local status=0
    local env_binary
    env_binary="$(command -v env)"
    log_file="$(mktemp "${TMPDIR:-/tmp}/dinox-remote-private-muc-smoke.XXXXXX.log")"

    if [[ "$SMOKE_KIND" = "bootstrap" ]]; then
        run_with_build_runtime_path "$env_binary" -u DINOX_REMOTE_MUC_SMOKE DINOX_REMOTE_MUC_BOOTSTRAP=1 "$test_binary" -p "$BOOTSTRAP_TEST_PATH" > "$log_file" 2>&1 || status="$?"
    else
        run_with_build_runtime_path "$env_binary" -u DINOX_REMOTE_MUC_BOOTSTRAP DINOX_REMOTE_MUC_SMOKE=1 "$test_binary" -p "$PREPARED_ROOM_TEST_PATH" > "$log_file" 2>&1 || status="$?"
    fi

    if ((status != 0)); then
        error "remote private-MUC smoke failed"
        sanitize_log "$log_file" >&2
        rm -f "$log_file"
        return "$status"
    fi

    rm -f "$log_file"
    if [[ "$SMOKE_KIND" = "bootstrap" ]]; then
        echo "remote-private-muc-bootstrap-ok"
    else
        echo "remote-private-muc-prepared-room-ok"
    fi
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --preflight)
            MODE="preflight"
            shift
            ;;
        --bootstrap)
            SMOKE_KIND="bootstrap"
            shift
            ;;
        --prepared-room)
            SMOKE_KIND="prepared-room"
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
    echo "Remote private-MUC smoke preflight OK"
    echo "Mode: $SMOKE_KIND"
    if [[ "$SMOKE_KIND" = "bootstrap" ]]; then
        echo "Focused test: $BOOTSTRAP_TEST_PATH"
    else
        echo "Focused test: $PREPARED_ROOM_TEST_PATH"
    fi
    echo "Build dir: $BUILD_DIR"
    exit 0
fi

run_smoke
