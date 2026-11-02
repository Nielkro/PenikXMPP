#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
TEST_PATH="/RemoteOpenPgpPrivateMucHttpSmoke/private_muc_xep0374_http_send_receive_env"
KEY_SETUP="seeded"
MODE="run"

usage() {
    cat <<EOF
Usage: $0 [--preflight] [--pubsub-discovery|--legacy-xep0027|--direct-sender-only|--direct-legacy-xep0027-sender-only] [--build-dir DIR]

Runs the env-backed remote private-MUC DinoX-to-DinoX OpenPGP HTTP
file-send/receive smoke. The default path uses seeded local XEP-0373/XEP-0374
contact keys; --pubsub-discovery publishes and fetches those keys through real
remote XEP-0373 PubSub before sending. --legacy-xep0027 selects the legacy
XEP-0027 path with temporary email-UID keys and signed-presence activation.
--direct-sender-only selects a one-to-one XEP-0374 HTTP sender gate for pairing
the headless sender with a packaged GUI receiver. --direct-legacy-xep0027-sender-only
selects the matching one-to-one legacy XEP-0027 sender gate.

Private-MUC required environment:
  DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_JID
  DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_PASSWORD
  DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_JID
  DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_PASSWORD
  DINOX_REMOTE_OPENPGP_MUC_SERVICE

Private-MUC optional environment:
  DINOX_REMOTE_OPENPGP_MUC_HOST
  DINOX_REMOTE_OPENPGP_MUC_PORT
  DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_NICK
  DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_NICK
  DINOX_REMOTE_OPENPGP_MUC_BOOTSTRAP_ROOM_PREFIX
  DINOX_REMOTE_OPENPGP_MUC_TIMEOUT_SECONDS
  DINOX_REMOTE_OPENPGP_MUC_FILE_NAME
  DINOX_REMOTE_OPENPGP_MUC_FILE_PAYLOAD_TEXT
  DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_TYPE=none|socks5|tor
  DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_HOST
  DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_PORT

Direct sender required environment:
  DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_JID
  DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_PASSWORD
  DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_JID
  DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_SECRET_KEY_FILE
  DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_PUBLIC_KEY_FILE
  DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_FINGERPRINT
  DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_FINGERPRINT

Direct sender optional environment:
  DINOX_REMOTE_OPENPGP_HTTP_FILE_HOST
  DINOX_REMOTE_OPENPGP_HTTP_FILE_PORT
  DINOX_REMOTE_OPENPGP_HTTP_FILE_ALLOW_PEP_MUTATION
  DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY
  DINOX_REMOTE_OPENPGP_HTTP_FILE_KEEP_PUBLISHED_SENDER_KEY
  DINOX_REMOTE_OPENPGP_HTTP_FILE_BEFORE_SEND_GATE_FILE
  DINOX_REMOTE_OPENPGP_HTTP_FILE_AFTER_SEND_HOLD_FILE
  DINOX_REMOTE_OPENPGP_HTTP_FILE_TIMEOUT_SECONDS
  DINOX_REMOTE_OPENPGP_HTTP_FILE_NAME
  DINOX_REMOTE_OPENPGP_HTTP_FILE_PAYLOAD_TEXT

Options:
  --preflight       Validate required environment and local build target only.
  --pubsub-discovery
                   Run without seeded contact keys, using real remote XEP-0373
                   PubSub publish/fetch for sender and receiver key readiness.
  --legacy-xep0027
                   Run the legacy XEP-0027 private-MUC HTTP smoke with
                   temporary email-UID OpenPGP keys and signed presence.
  --direct-sender-only
                   Run only the direct one-to-one XEP-0374 HTTP sender path.
  --direct-legacy-xep0027-sender-only
                   Run only the direct one-to-one legacy XEP-0027 HTTP sender path.
  --build-dir       Use a non-default Meson build directory.
  --help            Show this help.

The runner never prints passwords, full JIDs, generated room JIDs, payload text,
OpenPGP fingerprints, temporary GNUPGHOME paths, or upload/download URLs. The
smoke creates isolated temporary OpenPGP keys, uploads one tiny synthetic .pgp
file to the configured server, keeps the receiver online, and verifies both the
uploaded .pgp body and the receiver-side decrypted local store.
In direct sender-only modes it imports the process-scoped sender secret key and
receiver public key into an isolated GNUPGHOME, uploads one tiny synthetic .pgp
file, and verifies the selected XEP-0374 or XEP-0027 encrypted upload/body-url
sender boundary for a separately controlled receiver.
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

validate_account_proxy_env() {
    local proxy_type="${DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_TYPE:-}"
    if [[ -z "$proxy_type" ]]; then
        return 0
    fi
    validate_no_newline DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_TYPE "$proxy_type"
    proxy_type="${proxy_type,,}"
    if [[ "$proxy_type" != "none" && "$proxy_type" != "socks5" && "$proxy_type" != "tor" ]]; then
        error "DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_TYPE must be none, socks5 or tor"
        return 1
    fi
    if [[ "$proxy_type" == "none" ]]; then
        return 0
    fi

    if [[ -n "${DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_HOST:-}" ]]; then
        validate_no_newline DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_HOST "$DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_HOST"
    elif [[ "$proxy_type" == "socks5" ]]; then
        error "DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_HOST must be set for socks5 account proxy"
        return 1
    fi

    if [[ -n "${DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_PORT:-}" ]]; then
        validate_no_newline DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_PORT "$DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_PORT"
        if ! is_integer "$DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_PORT"; then
            error "DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_PORT must be an integer between 1 and 65535"
            return 1
        fi
        local proxy_port
        proxy_port="$(parse_uint10 "$DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_PORT")"
        if ((proxy_port < 1 || proxy_port > 65535)); then
            error "DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_PORT must be an integer between 1 and 65535"
            return 1
        fi
    elif [[ "$proxy_type" == "socks5" ]]; then
        error "DINOX_REMOTE_OPENPGP_MUC_ACCOUNT_PROXY_PORT must be set for socks5 account proxy"
        return 1
    fi
}

validate_fingerprint() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[A-Fa-f0-9][A-Fa-f0-9:\ ]{38,78}[A-Fa-f0-9]$ ]]; then
        error "$name must be a full 40-hex OpenPGP fingerprint"
        return 1
    fi
    local normalized
    normalized="$(printf '%s' "$value" | tr -d ' :' | tr '[:lower:]' '[:upper:]')"
    if [[ ! "$normalized" =~ ^[A-F0-9]{40}$ ]]; then
        error "$name must be a full 40-hex OpenPGP fingerprint"
        return 1
    fi
}

validate_env() {
    if [[ "$KEY_SETUP" = "direct-sender" || "$KEY_SETUP" = "direct-legacy-xep0027" ]]; then
        validate_direct_sender_env
        return
    fi

    MISSING_ENV=()
    require_env DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_JID
    require_env DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_PASSWORD
    require_env DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_JID
    require_env DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_PASSWORD
    require_env DINOX_REMOTE_OPENPGP_MUC_SERVICE

    if [[ "${#MISSING_ENV[@]}" -gt 0 ]]; then
        error "missing required environment:"
        printf '  %s\n' "${MISSING_ENV[@]}" >&2
        return 1
    fi

    validate_no_newline DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_JID "$DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_JID"
    validate_no_newline DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_PASSWORD "$DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_PASSWORD"
    validate_no_newline DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_JID "$DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_JID"
    validate_no_newline DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_PASSWORD "$DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_PASSWORD"
    validate_no_newline DINOX_REMOTE_OPENPGP_MUC_SERVICE "$DINOX_REMOTE_OPENPGP_MUC_SERVICE"
    validate_account_jid DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_JID "$DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_JID"
    validate_account_jid DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_JID "$DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_JID"
    validate_domain_jid DINOX_REMOTE_OPENPGP_MUC_SERVICE "$DINOX_REMOTE_OPENPGP_MUC_SERVICE"

    if [[ "$DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_JID" == "$DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_JID" ]]; then
        error "sender and receiver accounts must be distinct"
        return 1
    fi

    for name in \
        DINOX_REMOTE_OPENPGP_MUC_HOST \
        DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_NICK \
        DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_NICK \
        DINOX_REMOTE_OPENPGP_MUC_BOOTSTRAP_ROOM_PREFIX \
        DINOX_REMOTE_OPENPGP_MUC_FILE_PAYLOAD_TEXT
    do
        if [[ -n "${!name:-}" ]]; then
            validate_no_newline "$name" "${!name}"
        fi
    done

    if [[ -n "${DINOX_REMOTE_OPENPGP_MUC_FILE_NAME:-}" ]]; then
        validate_no_newline DINOX_REMOTE_OPENPGP_MUC_FILE_NAME "$DINOX_REMOTE_OPENPGP_MUC_FILE_NAME"
        validate_payload_name DINOX_REMOTE_OPENPGP_MUC_FILE_NAME "$DINOX_REMOTE_OPENPGP_MUC_FILE_NAME"
    fi

    if [[ -n "${DINOX_REMOTE_OPENPGP_MUC_PORT:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_OPENPGP_MUC_PORT"; then
            error "DINOX_REMOTE_OPENPGP_MUC_PORT must be an integer between 1 and 65535"
            return 1
        fi
        local port
        port="$(parse_uint10 "$DINOX_REMOTE_OPENPGP_MUC_PORT")"
        if ((port < 1 || port > 65535)); then
            error "DINOX_REMOTE_OPENPGP_MUC_PORT must be an integer between 1 and 65535"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_OPENPGP_MUC_TIMEOUT_SECONDS:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_OPENPGP_MUC_TIMEOUT_SECONDS"; then
            error "DINOX_REMOTE_OPENPGP_MUC_TIMEOUT_SECONDS must be an integer between 5 and 900"
            return 1
        fi
        local timeout
        timeout="$(parse_uint10 "$DINOX_REMOTE_OPENPGP_MUC_TIMEOUT_SECONDS")"
        if ((timeout < 5 || timeout > 900)); then
            error "DINOX_REMOTE_OPENPGP_MUC_TIMEOUT_SECONDS must be an integer between 5 and 900"
            return 1
        fi
    fi

    validate_account_proxy_env
}

validate_direct_sender_env() {
    MISSING_ENV=()
    require_env DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_JID
    require_env DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_PASSWORD
    require_env DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_JID
    require_env DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_SECRET_KEY_FILE
    require_env DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_PUBLIC_KEY_FILE
    require_env DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_FINGERPRINT
    require_env DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_FINGERPRINT

    if [[ "${#MISSING_ENV[@]}" -gt 0 ]]; then
        error "missing required environment:"
        printf '  %s\n' "${MISSING_ENV[@]}" >&2
        return 1
    fi

    validate_no_newline DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_JID "$DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_JID"
    validate_no_newline DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_PASSWORD "$DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_PASSWORD"
    validate_no_newline DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_JID "$DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_JID"
    validate_no_newline DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_SECRET_KEY_FILE "$DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_SECRET_KEY_FILE"
    validate_no_newline DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_PUBLIC_KEY_FILE "$DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_PUBLIC_KEY_FILE"
    validate_no_newline DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_FINGERPRINT "$DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_FINGERPRINT"
    validate_no_newline DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_FINGERPRINT "$DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_FINGERPRINT"
    validate_account_jid DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_JID "$DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_JID"
    validate_account_jid DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_JID "$DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_JID"
    validate_fingerprint DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_FINGERPRINT "$DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_FINGERPRINT"
    validate_fingerprint DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_FINGERPRINT "$DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_FINGERPRINT"

    if [[ "$DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_JID" == "$DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_JID" ]]; then
        error "sender and receiver accounts must be distinct"
        return 1
    fi
    if [[ "$(printf '%s' "$DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_FINGERPRINT" | tr -d ' :' | tr '[:lower:]' '[:upper:]')" == "$(printf '%s' "$DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_FINGERPRINT" | tr -d ' :' | tr '[:lower:]' '[:upper:]')" ]]; then
        error "sender and receiver OpenPGP fingerprints must be distinct"
        return 1
    fi
    if [[ ! -f "$DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_SECRET_KEY_FILE" ]]; then
        error "DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_SECRET_KEY_FILE must point to a regular file"
        return 1
    fi
    if [[ ! -f "$DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_PUBLIC_KEY_FILE" ]]; then
        error "DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_PUBLIC_KEY_FILE must point to a regular file"
        return 1
    fi

    for name in \
        DINOX_REMOTE_OPENPGP_HTTP_FILE_HOST \
        DINOX_REMOTE_OPENPGP_HTTP_FILE_ALLOW_PEP_MUTATION \
        DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY \
        DINOX_REMOTE_OPENPGP_HTTP_FILE_KEEP_PUBLISHED_SENDER_KEY \
        DINOX_REMOTE_OPENPGP_HTTP_FILE_BEFORE_SEND_GATE_FILE \
        DINOX_REMOTE_OPENPGP_HTTP_FILE_AFTER_SEND_HOLD_FILE \
        DINOX_REMOTE_OPENPGP_HTTP_FILE_PAYLOAD_TEXT
    do
        if [[ -n "${!name:-}" ]]; then
            validate_no_newline "$name" "${!name}"
        fi
    done
    if [[ -n "${DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY:-}" &&
            "$DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY" != "1" ]]; then
        error "DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY must be 1 when set"
        return 1
    fi
    if [[ -n "${DINOX_REMOTE_OPENPGP_HTTP_FILE_ALLOW_PEP_MUTATION:-}" &&
            "$DINOX_REMOTE_OPENPGP_HTTP_FILE_ALLOW_PEP_MUTATION" != "1" ]]; then
        error "DINOX_REMOTE_OPENPGP_HTTP_FILE_ALLOW_PEP_MUTATION must be 1 when set"
        return 1
    fi
    if [[ -n "${DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY:-}" &&
            -z "${DINOX_REMOTE_OPENPGP_HTTP_FILE_ALLOW_PEP_MUTATION:-}" ]]; then
        error "DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY requires DINOX_REMOTE_OPENPGP_HTTP_FILE_ALLOW_PEP_MUTATION=1 for disposable test accounts"
        return 1
    fi
    if [[ -n "${DINOX_REMOTE_OPENPGP_HTTP_FILE_KEEP_PUBLISHED_SENDER_KEY:-}" &&
            "$DINOX_REMOTE_OPENPGP_HTTP_FILE_KEEP_PUBLISHED_SENDER_KEY" != "1" ]]; then
        error "DINOX_REMOTE_OPENPGP_HTTP_FILE_KEEP_PUBLISHED_SENDER_KEY must be 1 when set"
        return 1
    fi
    if [[ "$KEY_SETUP" = "direct-legacy-xep0027" &&
            ( -n "${DINOX_REMOTE_OPENPGP_HTTP_FILE_ALLOW_PEP_MUTATION:-}" ||
              -n "${DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY:-}" ||
              -n "${DINOX_REMOTE_OPENPGP_HTTP_FILE_KEEP_PUBLISHED_SENDER_KEY:-}" ) ]]; then
        error "direct legacy XEP-0027 sender mode must not mutate XEP-0373 PubSub state"
        return 1
    fi
    if [[ -n "${DINOX_REMOTE_OPENPGP_HTTP_FILE_KEEP_PUBLISHED_SENDER_KEY:-}" &&
            -z "${DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY:-}" ]]; then
        error "DINOX_REMOTE_OPENPGP_HTTP_FILE_KEEP_PUBLISHED_SENDER_KEY requires DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY=1"
        return 1
    fi
    if [[ -n "${DINOX_REMOTE_OPENPGP_HTTP_FILE_BEFORE_SEND_GATE_FILE:-}" ]]; then
        validate_no_newline DINOX_REMOTE_OPENPGP_HTTP_FILE_BEFORE_SEND_GATE_FILE "$DINOX_REMOTE_OPENPGP_HTTP_FILE_BEFORE_SEND_GATE_FILE"
    fi
    if [[ -n "${DINOX_REMOTE_OPENPGP_HTTP_FILE_AFTER_SEND_HOLD_FILE:-}" ]]; then
        validate_no_newline DINOX_REMOTE_OPENPGP_HTTP_FILE_AFTER_SEND_HOLD_FILE "$DINOX_REMOTE_OPENPGP_HTTP_FILE_AFTER_SEND_HOLD_FILE"
    fi

    if [[ -n "${DINOX_REMOTE_OPENPGP_HTTP_FILE_NAME:-}" ]]; then
        validate_no_newline DINOX_REMOTE_OPENPGP_HTTP_FILE_NAME "$DINOX_REMOTE_OPENPGP_HTTP_FILE_NAME"
        validate_payload_name DINOX_REMOTE_OPENPGP_HTTP_FILE_NAME "$DINOX_REMOTE_OPENPGP_HTTP_FILE_NAME"
    fi

    if [[ -n "${DINOX_REMOTE_OPENPGP_HTTP_FILE_PORT:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_OPENPGP_HTTP_FILE_PORT"; then
            error "DINOX_REMOTE_OPENPGP_HTTP_FILE_PORT must be an integer between 1 and 65535"
            return 1
        fi
        local port
        port="$(parse_uint10 "$DINOX_REMOTE_OPENPGP_HTTP_FILE_PORT")"
        if ((port < 1 || port > 65535)); then
            error "DINOX_REMOTE_OPENPGP_HTTP_FILE_PORT must be an integer between 1 and 65535"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_OPENPGP_HTTP_FILE_TIMEOUT_SECONDS:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_OPENPGP_HTTP_FILE_TIMEOUT_SECONDS"; then
            error "DINOX_REMOTE_OPENPGP_HTTP_FILE_TIMEOUT_SECONDS must be an integer between 5 and 900"
            return 1
        fi
        local timeout
        timeout="$(parse_uint10 "$DINOX_REMOTE_OPENPGP_HTTP_FILE_TIMEOUT_SECONDS")"
        if ((timeout < 5 || timeout > 900)); then
            error "DINOX_REMOTE_OPENPGP_HTTP_FILE_TIMEOUT_SECONDS must be an integer between 5 and 900"
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
        -u DINOX_REMOTE_OPENPGP_MUC_HTTP_FILE_SMOKE \
        -u DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_JID \
        -u DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_PASSWORD \
        -u DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_JID \
        -u DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_PASSWORD \
        -u DINOX_REMOTE_OPENPGP_MUC_SERVICE \
        -u DINOX_REMOTE_OPENPGP_MUC_HOST \
        -u DINOX_REMOTE_OPENPGP_MUC_PORT \
        -u DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_NICK \
        -u DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_NICK \
        -u DINOX_REMOTE_OPENPGP_MUC_BOOTSTRAP_ROOM_PREFIX \
        -u DINOX_REMOTE_OPENPGP_MUC_TIMEOUT_SECONDS \
        -u DINOX_REMOTE_OPENPGP_MUC_FILE_NAME \
        -u DINOX_REMOTE_OPENPGP_MUC_FILE_PAYLOAD_TEXT \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_SMOKE \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_JID \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_PASSWORD \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_JID \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_SECRET_KEY_FILE \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_PUBLIC_KEY_FILE \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_FINGERPRINT \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_FINGERPRINT \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_HOST \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_PORT \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_ALLOW_PEP_MUTATION \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_KEEP_PUBLISHED_SENDER_KEY \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_BEFORE_SEND_GATE_FILE \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_AFTER_SEND_HOLD_FILE \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_TIMEOUT_SECONDS \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_NAME \
        -u DINOX_REMOTE_OPENPGP_HTTP_FILE_PAYLOAD_TEXT \
        meson compile -C "$BUILD_DIR" plugins/openpgp/openpgp-test
}

sanitize_log() {
    local log_file="$1"
    perl -0pe '
        for my $name (qw(
            DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_JID
            DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_PASSWORD
            DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_JID
            DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_PASSWORD
            DINOX_REMOTE_OPENPGP_MUC_SERVICE
            DINOX_REMOTE_OPENPGP_MUC_HOST
            DINOX_REMOTE_OPENPGP_MUC_FILE_SENDER_NICK
            DINOX_REMOTE_OPENPGP_MUC_FILE_RECEIVER_NICK
            DINOX_REMOTE_OPENPGP_MUC_BOOTSTRAP_ROOM_PREFIX
            DINOX_REMOTE_OPENPGP_MUC_FILE_NAME
            DINOX_REMOTE_OPENPGP_MUC_FILE_PAYLOAD_TEXT
            DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_JID
            DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_PASSWORD
            DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_JID
            DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_SECRET_KEY_FILE
            DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_PUBLIC_KEY_FILE
            DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_FINGERPRINT
            DINOX_REMOTE_OPENPGP_HTTP_FILE_RECEIVER_FINGERPRINT
            DINOX_REMOTE_OPENPGP_HTTP_FILE_HOST
            DINOX_REMOTE_OPENPGP_HTTP_FILE_ALLOW_PEP_MUTATION
            DINOX_REMOTE_OPENPGP_HTTP_FILE_PUBLISH_SENDER_KEY
            DINOX_REMOTE_OPENPGP_HTTP_FILE_KEEP_PUBLISHED_SENDER_KEY
            DINOX_REMOTE_OPENPGP_HTTP_FILE_BEFORE_SEND_GATE_FILE
            DINOX_REMOTE_OPENPGP_HTTP_FILE_AFTER_SEND_HOLD_FILE
            DINOX_REMOTE_OPENPGP_HTTP_FILE_NAME
            DINOX_REMOTE_OPENPGP_HTTP_FILE_PAYLOAD_TEXT
            GNUPGHOME
        )) {
            my $value = $ENV{$name};
            next if !defined($value) || $value eq "";
            s/\Q$value\E/<$name>/g;
        }
        s{<\{urn:xmpp:openpgp:0\}:data\b.*?</\{urn:xmpp:openpgp:0\}:data>}{<openpgp-public-key-data-redacted>}gs;
        s{<data\b[^>]*>[^<]{64,}</data>}{<openpgp-public-key-data-redacted>}gs;
        s{https?://[^\s<>"]+}{<remote-http-url>}g;
        s/[A-Fa-f0-9]{40}/<openpgp-fingerprint>/g;
        s{/(tmp|var/tmp)/[^\s<>"]*dinox-remote-openpgp[^\s<>"]*}{<remote-openpgp-temp-path>}g;
        s/dinox-remote-openpgp-muc-http-smoke-[0-9a-f-]+\@[A-Za-z0-9.-]+/<generated-openpgp-muc-room>/g;
        s/dinox-remote-openpgp-muc-http-smoke-[0-9a-f-]+/<generated-openpgp-temp-name>/g;
        s/dinox-remote-openpgp-private-muc-http-smoke-[0-9a-f-]+/<generated-openpgp-temp-name>/g;
        s/dinox-remote-openpgp-direct-http-sender-[0-9a-f-]+/<generated-openpgp-temp-name>/g;
    ' "$log_file"
}

run_smoke() {
    local test_binary="$BUILD_DIR/plugins/openpgp/openpgp-test"
    if [[ ! -x "$test_binary" ]]; then
        error "test binary not found: $test_binary"
        return 1
    fi

    local log_file
    local status=0
    log_file="$(mktemp "${TMPDIR:-/tmp}/dinox-remote-openpgp-private-muc-http-smoke.XXXXXX.log")"

    if [[ "$KEY_SETUP" = "direct-sender" || "$KEY_SETUP" = "direct-legacy-xep0027" ]]; then
        run_with_build_runtime_path DINOX_REMOTE_OPENPGP_HTTP_FILE_SENDER_SMOKE=1 "$test_binary" -p "$TEST_PATH" > "$log_file" 2>&1 || status="$?"
    else
        run_with_build_runtime_path DINOX_REMOTE_OPENPGP_MUC_HTTP_FILE_SMOKE=1 "$test_binary" -p "$TEST_PATH" > "$log_file" 2>&1 || status="$?"
    fi

    if ((status != 0)); then
        if [[ "$KEY_SETUP" = "direct-sender" || "$KEY_SETUP" = "direct-legacy-xep0027" ]]; then
            error "remote OpenPGP direct HTTP sender-only smoke failed"
        else
            error "remote OpenPGP private-MUC HTTP file-send/receive smoke failed"
        fi
        sanitize_log "$log_file" >&2
        rm -f "$log_file"
        return "$status"
    fi

    rm -f "$log_file"
    if [[ "$KEY_SETUP" = "direct-sender" ]]; then
        echo "remote-openpgp-direct-http-file-sender-ok"
    elif [[ "$KEY_SETUP" = "direct-legacy-xep0027" ]]; then
        echo "remote-openpgp-direct-xep0027-http-file-sender-ok"
    elif [[ "$KEY_SETUP" = "pubsub" ]]; then
        echo "remote-openpgp-pubsub-private-muc-http-file-send-receive-ok"
    elif [[ "$KEY_SETUP" = "legacy-xep0027" ]]; then
        echo "remote-openpgp-xep0027-private-muc-http-file-send-receive-ok"
    else
        echo "remote-openpgp-private-muc-http-file-send-receive-ok"
    fi
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --preflight)
            MODE="preflight"
            shift
            ;;
        --pubsub-discovery|--xep0373-pubsub)
            TEST_PATH="/RemoteOpenPgpPrivateMucHttpSmoke/private_muc_xep0374_pubsub_http_send_receive_env"
            KEY_SETUP="pubsub"
            shift
            ;;
        --legacy-xep0027|--xep0027-legacy)
            TEST_PATH="/RemoteOpenPgpPrivateMucHttpSmoke/private_muc_xep0027_http_send_receive_env"
            KEY_SETUP="legacy-xep0027"
            shift
            ;;
        --direct-sender-only|--direct-xep0374-sender)
            TEST_PATH="/RemoteOpenPgpPrivateMucHttpSmoke/direct_xep0374_http_sender_env"
            KEY_SETUP="direct-sender"
            shift
            ;;
        --direct-legacy-xep0027-sender-only|--direct-xep0027-sender)
            TEST_PATH="/RemoteOpenPgpPrivateMucHttpSmoke/direct_xep0027_http_sender_env"
            KEY_SETUP="direct-legacy-xep0027"
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
    if [[ "$KEY_SETUP" = "direct-sender" ]]; then
        echo "Remote OpenPGP direct HTTP sender-only smoke preflight OK"
    elif [[ "$KEY_SETUP" = "direct-legacy-xep0027" ]]; then
        echo "Remote OpenPGP direct legacy XEP-0027 HTTP sender-only smoke preflight OK"
    else
        echo "Remote OpenPGP private-MUC HTTP file-send/receive smoke preflight OK"
    fi
    echo "Focused test: $TEST_PATH"
    echo "Build dir: $BUILD_DIR"
    exit 0
fi

run_smoke
