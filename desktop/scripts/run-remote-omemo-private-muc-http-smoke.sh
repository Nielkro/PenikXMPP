#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
TEST_PATH="/RemoteOmemoPrivateMucHttpSmoke/private_muc_omemo1_http_send_receive_env"
PROTOCOL="omemo1"
MODE="run"

usage() {
    cat <<EOF
Usage: $0 [--preflight] [--omemo1|--omemo2|--pubsub-discovery|--omemo2-pubsub-discovery] [--build-dir DIR]

Runs the env-backed remote private-MUC DinoX-to-DinoX OMEMO HTTP file-send
and receive smoke. OMEMO1 is the default; --omemo2 selects the seeded
OMEMO2/SCE runtime path. --pubsub-discovery selects the legacy OMEMO1 path
that discovers receiver devices and bundles through real remote PubSub.
--omemo2-pubsub-discovery selects the OMEMO2/SCE path with controlled v2-only
remote PubSub device and bundle discovery.

Required environment:
  DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_JID
  DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_PASSWORD
  DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_JID
  DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_PASSWORD
  DINOX_REMOTE_OMEMO_MUC_SERVICE

Optional environment:
  DINOX_REMOTE_OMEMO_MUC_HOST
  DINOX_REMOTE_OMEMO_MUC_PORT
  DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_NICK
  DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_NICK
  DINOX_REMOTE_OMEMO_MUC_BOOTSTRAP_ROOM_PREFIX
  DINOX_REMOTE_OMEMO_MUC_TIMEOUT_SECONDS
  DINOX_REMOTE_OMEMO_MUC_FILE_NAME
  DINOX_REMOTE_OMEMO_MUC_FILE_PAYLOAD_TEXT
  DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID
  DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_PASSWORD
  DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_NICK
  DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_TYPE=none|socks5|tor
  DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_HOST
  DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_PORT
  DINOX_REMOTE_OMEMO_MUC_ALLOW_PEP_MUTATION=1
    Required only for --omemo2-pubsub-discovery. That mode temporarily rewrites
    disposable account OMEMO PEP device-list and bundle state, then restores it.

Options:
  --preflight       Validate required environment and local build target only.
  --omemo1          Run the legacy OMEMO1 private-MUC smoke (default).
  --pubsub-discovery
                   Run the legacy OMEMO1 private-MUC smoke without seeded
                   sessions/trust, using remote PubSub device/bundle discovery.
  --omemo2          Run the OMEMO2/SCE private-MUC smoke.
  --omemo2-pubsub-discovery
                   Run the OMEMO2/SCE private-MUC smoke without seeded
                   sessions/trust, using remote PubSub v2 device/bundle
                   discovery.
  --build-dir       Use a non-default Meson build directory.
  --help            Show this help.

The runner never prints passwords, full JIDs, generated room JIDs, payload text,
upload/download URLs, aesgcm URL secrets or temp paths. The smoke uploads one
tiny synthetic file to the configured server; server-side HTTP upload retention
is controlled by the server.
EOF
}

set_protocol() {
    PROTOCOL="$1"
    case "$PROTOCOL" in
        omemo1)
            TEST_PATH="/RemoteOmemoPrivateMucHttpSmoke/private_muc_omemo1_http_send_receive_env"
            ;;
        omemo1-pubsub)
            TEST_PATH="/RemoteOmemoPrivateMucHttpSmoke/private_muc_omemo1_pubsub_http_send_receive_env"
            ;;
        omemo2)
            TEST_PATH="/RemoteOmemoPrivateMucHttpSmoke/private_muc_omemo2_http_send_receive_env"
            ;;
        omemo2-pubsub)
            TEST_PATH="/RemoteOmemoPrivateMucHttpSmoke/private_muc_omemo2_pubsub_http_send_receive_env"
            ;;
        *)
            error "unknown OMEMO protocol: $PROTOCOL"
            return 1
            ;;
    esac
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

validate_account_proxy_env() {
    local proxy_type="${DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_TYPE:-}"
    if [[ -z "$proxy_type" ]]; then
        return 0
    fi
    validate_no_newline DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_TYPE "$proxy_type"
    proxy_type="${proxy_type,,}"
    if [[ "$proxy_type" != "none" && "$proxy_type" != "socks5" && "$proxy_type" != "tor" ]]; then
        error "DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_TYPE must be none, socks5 or tor"
        return 1
    fi
    if [[ "$proxy_type" == "none" ]]; then
        return 0
    fi

    if [[ -n "${DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_HOST:-}" ]]; then
        validate_no_newline DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_HOST "$DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_HOST"
    elif [[ "$proxy_type" == "socks5" ]]; then
        error "DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_HOST must be set for socks5 account proxy"
        return 1
    fi

    if [[ -n "${DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_PORT:-}" ]]; then
        validate_no_newline DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_PORT "$DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_PORT"
        if ! is_integer "$DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_PORT"; then
            error "DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_PORT must be an integer between 1 and 65535"
            return 1
        fi
        local proxy_port
        proxy_port="$(parse_uint10 "$DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_PORT")"
        if ((proxy_port < 1 || proxy_port > 65535)); then
            error "DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_PORT must be an integer between 1 and 65535"
            return 1
        fi
    elif [[ "$proxy_type" == "socks5" ]]; then
        error "DINOX_REMOTE_OMEMO_MUC_ACCOUNT_PROXY_PORT must be set for socks5 account proxy"
        return 1
    fi
}

validate_env() {
    MISSING_ENV=()
    require_env DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_JID
    require_env DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_PASSWORD
    require_env DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_JID
    require_env DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_PASSWORD
    require_env DINOX_REMOTE_OMEMO_MUC_SERVICE

    if [[ "${#MISSING_ENV[@]}" -gt 0 ]]; then
        error "missing required environment:"
        printf '  %s\n' "${MISSING_ENV[@]}" >&2
        return 1
    fi

    validate_no_newline DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_JID "$DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_JID"
    validate_no_newline DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_PASSWORD "$DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_PASSWORD"
    validate_no_newline DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_JID "$DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_JID"
    validate_no_newline DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_PASSWORD "$DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_PASSWORD"
    validate_no_newline DINOX_REMOTE_OMEMO_MUC_SERVICE "$DINOX_REMOTE_OMEMO_MUC_SERVICE"
    validate_account_jid DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_JID "$DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_JID"
    validate_account_jid DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_JID "$DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_JID"
    validate_domain_jid DINOX_REMOTE_OMEMO_MUC_SERVICE "$DINOX_REMOTE_OMEMO_MUC_SERVICE"

    if [[ "$PROTOCOL" == "omemo2-pubsub" ]]; then
        if [[ "${DINOX_REMOTE_OMEMO_MUC_ALLOW_PEP_MUTATION:-}" != "1" ]]; then
            error "DINOX_REMOTE_OMEMO_MUC_ALLOW_PEP_MUTATION=1 is required for --omemo2-pubsub-discovery because it temporarily rewrites disposable account PEP nodes"
            return 1
        fi
        validate_no_newline DINOX_REMOTE_OMEMO_MUC_ALLOW_PEP_MUTATION "$DINOX_REMOTE_OMEMO_MUC_ALLOW_PEP_MUTATION"
    fi

    if [[ "$DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_JID" == "$DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_JID" ]]; then
        error "sender and receiver accounts must be distinct"
        return 1
    fi
    if [[ -n "${DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID:-}" || -n "${DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_PASSWORD:-}" ]]; then
        if [[ -z "${DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID:-}" || -z "${DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_PASSWORD:-}" ]]; then
            error "DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID and DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_PASSWORD must be set together"
            return 1
        fi
        validate_no_newline DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID "$DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID"
        validate_no_newline DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_PASSWORD "$DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_PASSWORD"
        validate_account_jid DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID "$DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID"
        if [[ "$DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID" == "$DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_JID" ||
              "$DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID" == "$DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_JID" ]]; then
            error "sender, receiver and extra receiver accounts must be distinct"
            return 1
        fi
    fi

    for name in \
        DINOX_REMOTE_OMEMO_MUC_HOST \
        DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_NICK \
        DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_NICK \
        DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_NICK \
        DINOX_REMOTE_OMEMO_MUC_BOOTSTRAP_ROOM_PREFIX \
        DINOX_REMOTE_OMEMO_MUC_FILE_PAYLOAD_TEXT
    do
        if [[ -n "${!name:-}" ]]; then
            validate_no_newline "$name" "${!name}"
        fi
    done

    if [[ -n "${DINOX_REMOTE_OMEMO_MUC_FILE_NAME:-}" ]]; then
        validate_no_newline DINOX_REMOTE_OMEMO_MUC_FILE_NAME "$DINOX_REMOTE_OMEMO_MUC_FILE_NAME"
        validate_payload_name DINOX_REMOTE_OMEMO_MUC_FILE_NAME "$DINOX_REMOTE_OMEMO_MUC_FILE_NAME"
    fi

    if [[ -n "${DINOX_REMOTE_OMEMO_MUC_PORT:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_OMEMO_MUC_PORT"; then
            error "DINOX_REMOTE_OMEMO_MUC_PORT must be an integer between 1 and 65535"
            return 1
        fi
        local port
        port="$(parse_uint10 "$DINOX_REMOTE_OMEMO_MUC_PORT")"
        if ((port < 1 || port > 65535)); then
            error "DINOX_REMOTE_OMEMO_MUC_PORT must be an integer between 1 and 65535"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_OMEMO_MUC_TIMEOUT_SECONDS:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_OMEMO_MUC_TIMEOUT_SECONDS"; then
            error "DINOX_REMOTE_OMEMO_MUC_TIMEOUT_SECONDS must be an integer between 5 and 900"
            return 1
        fi
        local timeout
        timeout="$(parse_uint10 "$DINOX_REMOTE_OMEMO_MUC_TIMEOUT_SECONDS")"
        if ((timeout < 5 || timeout > 900)); then
            error "DINOX_REMOTE_OMEMO_MUC_TIMEOUT_SECONDS must be an integer between 5 and 900"
            return 1
        fi
    fi

    validate_account_proxy_env
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
        -u DINOX_REMOTE_OMEMO_MUC_HTTP_FILE_SMOKE \
        -u DINOX_REMOTE_OMEMO_MUC_ALLOW_PEP_MUTATION \
        -u DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_JID \
        -u DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_PASSWORD \
        -u DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_JID \
        -u DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_PASSWORD \
        -u DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID \
        -u DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_PASSWORD \
        -u DINOX_REMOTE_OMEMO_MUC_SERVICE \
        -u DINOX_REMOTE_OMEMO_MUC_HOST \
        -u DINOX_REMOTE_OMEMO_MUC_PORT \
        -u DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_NICK \
        -u DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_NICK \
        -u DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_NICK \
        -u DINOX_REMOTE_OMEMO_MUC_BOOTSTRAP_ROOM_PREFIX \
        -u DINOX_REMOTE_OMEMO_MUC_TIMEOUT_SECONDS \
        -u DINOX_REMOTE_OMEMO_MUC_FILE_NAME \
        -u DINOX_REMOTE_OMEMO_MUC_FILE_PAYLOAD_TEXT \
        meson compile -C "$BUILD_DIR" plugins/omemo/omemo-test
}

sanitize_log() {
    local log_file="$1"
    perl -0pe '
        s{<\{eu\.siacs\.conversations\.axolotl\}:bundle\b.*?</\{eu\.siacs\.conversations\.axolotl\}:bundle>}{<omemo1-bundle-redacted>}gs;
        s{<\{urn:xmpp:omemo:2\}:bundle\b.*?</\{urn:xmpp:omemo:2\}:bundle>}{<omemo2-bundle-redacted>}gs;
        for my $name (qw(
            DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_JID
            DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_PASSWORD
            DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_JID
            DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_PASSWORD
            DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_JID
            DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_PASSWORD
            DINOX_REMOTE_OMEMO_MUC_SERVICE
            DINOX_REMOTE_OMEMO_MUC_HOST
            DINOX_REMOTE_OMEMO_MUC_FILE_SENDER_NICK
            DINOX_REMOTE_OMEMO_MUC_FILE_RECEIVER_NICK
            DINOX_REMOTE_OMEMO_MUC_FILE_EXTRA_RECEIVER_NICK
            DINOX_REMOTE_OMEMO_MUC_BOOTSTRAP_ROOM_PREFIX
            DINOX_REMOTE_OMEMO_MUC_FILE_NAME
            DINOX_REMOTE_OMEMO_MUC_FILE_PAYLOAD_TEXT
        )) {
            my $value = $ENV{$name};
            next if !defined($value) || $value eq "";
            s/\Q$value\E/<$name>/g;
        }
        s{aesgcm://[^\s<>"]+}{<omemo-aesgcm-url>}g;
        s{https?://[^\s<>"]+}{<remote-http-url>}g;
        s{/(tmp|var/tmp)/[^\s<>"]*dinox-remote-omemo[^\s<>"]*}{<remote-omemo-temp-path>}g;
        s/dinox-remote-omemo-muc-http-smoke-[0-9a-f-]+\@[A-Za-z0-9.-]+/<generated-omemo-muc-room>/g;
        s/dinox-remote-omemo-muc-http-smoke-[0-9a-f-]+/<generated-omemo-temp-name>/g;
        s/dinox-remote-omemo-private-muc-http-smoke-[0-9a-f-]+/<generated-omemo-temp-name>/g;
    ' "$log_file"
}

run_smoke() {
    local test_binary="$BUILD_DIR/plugins/omemo/omemo-test"
    if [[ ! -x "$test_binary" ]]; then
        error "test binary not found: $test_binary"
        return 1
    fi

    local log_file
    local status=0
    log_file="$(mktemp "${TMPDIR:-/tmp}/dinox-remote-omemo-private-muc-http-smoke.XXXXXX.log")"

    run_with_build_runtime_path DINOX_REMOTE_OMEMO_MUC_HTTP_FILE_SMOKE=1 "$test_binary" -p "$TEST_PATH" > "$log_file" 2>&1 || status="$?"

    if ((status != 0)); then
        error "remote $PROTOCOL private-MUC HTTP file send/receive smoke failed"
        sanitize_log "$log_file" >&2
        rm -f "$log_file"
        return "$status"
    fi

    rm -f "$log_file"
    echo "remote-${PROTOCOL}-private-muc-http-file-send-receive-ok"
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --preflight)
            MODE="preflight"
            shift
            ;;
        --omemo1)
            set_protocol omemo1
            shift
            ;;
        --omemo2)
            set_protocol omemo2
            shift
            ;;
        --pubsub-discovery|--omemo1-pubsub)
            set_protocol omemo1-pubsub
            shift
            ;;
        --omemo2-pubsub-discovery|--omemo2-pubsub)
            set_protocol omemo2-pubsub
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
    echo "Remote $PROTOCOL private-MUC HTTP file send/receive smoke preflight OK"
    echo "Focused test: $TEST_PATH"
    echo "Build dir: $BUILD_DIR"
    exit 0
fi

run_smoke
