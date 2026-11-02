#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
FOREIGN_TEST_PATH="/RemoteJingleS5bSmoke/incoming_foreign_client_s5b_env"
PAIR_TEST_PATH="/RemoteJingleS5bSmoke/incoming_dinox_pair_s5b_env"
RAW_TEST_PATH="/RemoteJingleS5bSmoke/incoming_raw_sender_s5b_env"
PROXY_NO_DIRECT_TEST_PATH="/RemoteJingleS5bSmoke/incoming_proxy_no_direct_s5b_env"
STANDALONE_SENDER="$PROJECT_DIR/scripts/foreign-jingle-s5b-sender.py"
GUARD_PROXY="$PROJECT_DIR/scripts/remote-jingle-s5b-guard-proxy.py"
STANDALONE_MAX_PAYLOAD_SIZE=4999999
STANDALONE_TEMP_DIR=""
STANDALONE_RECEIVER_PID=""
STANDALONE_GUARD_PID=""
STANDALONE_TOR_PID=""
STANDALONE_TOR_MONITOR_PID=""

MODE="run"
SMOKE_KIND="foreign"

usage() {
    cat <<EOF
Usage: $0 [--preflight] [--dinox-pair|--raw-sender|--standalone-sender|--standalone-sender-proxy-no-direct|--standalone-sender-proxy-success|--standalone-sender-real-tor-no-direct|--standalone-sender-real-tor-onion-success|--standalone-sender-real-tor-public-success|--standalone-sender-real-tor-stable-public-success|--standalone-sender-real-tor-stable-proxy-success|--external-receiver-sender] [--build-dir DIR]

Runs the env-backed remote Jingle S5B receive-store smoke test.

Required environment for the foreign-client smoke:
  DINOX_REMOTE_JINGLE_S5B_JID
  DINOX_REMOTE_JINGLE_S5B_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_SENDER_JID
  DINOX_REMOTE_JINGLE_S5B_EXPECTED_NAME
  DINOX_REMOTE_JINGLE_S5B_EXPECTED_SIZE
  DINOX_REMOTE_JINGLE_S5B_EXPECTED_SHA256

Required environment for --dinox-pair:
  DINOX_REMOTE_JINGLE_S5B_JID
  DINOX_REMOTE_JINGLE_S5B_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_SENDER_JID
  DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD

Required environment for --raw-sender:
  DINOX_REMOTE_JINGLE_S5B_JID
  DINOX_REMOTE_JINGLE_S5B_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_SENDER_JID
  DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD

Required environment for --standalone-sender:
  DINOX_REMOTE_JINGLE_S5B_JID
  DINOX_REMOTE_JINGLE_S5B_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_SENDER_JID
  DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD

Required environment for --standalone-sender-proxy-no-direct:
  DINOX_REMOTE_JINGLE_S5B_JID
  DINOX_REMOTE_JINGLE_S5B_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_SENDER_JID
  DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD

Required environment for --standalone-sender-proxy-success:
  DINOX_REMOTE_JINGLE_S5B_JID
  DINOX_REMOTE_JINGLE_S5B_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_SENDER_JID
  DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD

Required environment for --standalone-sender-real-tor-no-direct:
  DINOX_REMOTE_JINGLE_S5B_JID
  DINOX_REMOTE_JINGLE_S5B_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_SENDER_JID
  DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD

Required environment for --standalone-sender-real-tor-onion-success:
  DINOX_REMOTE_JINGLE_S5B_JID
  DINOX_REMOTE_JINGLE_S5B_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_SENDER_JID
  DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD

Required environment for --standalone-sender-real-tor-public-success:
  DINOX_REMOTE_JINGLE_S5B_JID
  DINOX_REMOTE_JINGLE_S5B_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_SENDER_JID
  DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_HOST
  DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT

Required environment for --standalone-sender-real-tor-stable-public-success:
  DINOX_REMOTE_JINGLE_S5B_JID
  DINOX_REMOTE_JINGLE_S5B_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_SENDER_JID
  DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_HOST
  DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT
  DINOX_REMOTE_JINGLE_S5B_STABLE_PUBLIC_ENDPOINT=1

Required environment for --standalone-sender-real-tor-stable-proxy-success:
  DINOX_REMOTE_JINGLE_S5B_JID
  DINOX_REMOTE_JINGLE_S5B_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_SENDER_JID
  DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_HOST
  DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT
  DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_JID
  DINOX_REMOTE_JINGLE_S5B_STABLE_PUBLIC_ENDPOINT=1

Required environment for --external-receiver-sender:
  DINOX_REMOTE_JINGLE_S5B_SENDER_JID
  DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD
  DINOX_REMOTE_JINGLE_S5B_RECEIVER_FULL_JID or DINOX_REMOTE_JINGLE_S5B_READY_FILE

Optional environment:
  DINOX_REMOTE_JINGLE_S5B_HOST
  DINOX_REMOTE_JINGLE_S5B_PORT
  DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS
  DINOX_REMOTE_JINGLE_S5B_READY_FILE
  DINOX_REMOTE_JINGLE_S5B_PAIR_NAME
  DINOX_REMOTE_JINGLE_S5B_RAW_NAME
  DINOX_REMOTE_JINGLE_S5B_STANDALONE_NAME
  DINOX_REMOTE_JINGLE_S5B_STANDALONE_PAYLOAD_FILE
  DINOX_REMOTE_JINGLE_S5B_STANDALONE_CANDIDATE_HOST
  DINOX_REMOTE_JINGLE_S5B_STANDALONE_CANDIDATE_PORT
  DINOX_REMOTE_JINGLE_S5B_STANDALONE_LISTEN_HOST
  DINOX_REMOTE_JINGLE_S5B_STANDALONE_LISTEN_PORT
  DINOX_REMOTE_JINGLE_S5B_TOR_PATH
  DINOX_REMOTE_JINGLE_S5B_TOR_BOOTSTRAP_TIMEOUT_SECONDS
  DINOX_REMOTE_JINGLE_S5B_REQUIRE_TOR_REJECT_LOG
  DINOX_REMOTE_JINGLE_S5B_ONION_VIRTUAL_PORT
  DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_HOST
  DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_PORT

Options:
  --preflight          Validate required environment and local build target only.
  --dinox-pair         Use two DinoX accounts to drive a real-server DinoX-to-DinoX S5B smoke.
  --raw-sender         Use a scripted sender inside libdino without offer_file_stream().
  --standalone-sender  Start the receiver smoke and a stdlib-only Python XMPP/Jingle S5B sender.
  --standalone-sender-proxy-no-direct
                       Start a SOCKS5 guard proxy and require clean failure without direct S5B.
  --standalone-sender-proxy-success
                       Start a SOCKS5 guard proxy and require successful proxied S5B receive-store.
  --standalone-sender-real-tor-no-direct
                       Start an isolated local Tor SOCKS daemon and require clean failure without direct S5B.
  --standalone-sender-real-tor-onion-success
                       Start an isolated local Tor hidden service and require successful S5B receive-store through Tor.
  --standalone-sender-real-tor-public-success
                       Start an isolated local Tor SOCKS daemon and require successful S5B receive-store through a public S5B candidate.
  --standalone-sender-real-tor-stable-public-success
                       Same public-candidate proof, but only for an explicitly acknowledged stable self-owned endpoint.
  --standalone-sender-real-tor-stable-proxy-success
                       Require successful S5B receive-store through a stable self-owned public XEP-0065 proxy candidate.
  --external-receiver-sender
                       Run only the stdlib XMPP/Jingle S5B sender against an externally started receiver full JID.
  --build-dir          Use a non-default Meson build directory.
  --help               Show this help.

The runner never prints the password or full environment values.
EOF
}

error() {
    echo "ERROR: $*" >&2
}

cleanup_standalone_sender_smoke() {
    if [[ -n "${STANDALONE_TOR_MONITOR_PID:-}" ]] && kill -0 "$STANDALONE_TOR_MONITOR_PID" 2>/dev/null; then
        kill "$STANDALONE_TOR_MONITOR_PID" 2>/dev/null || true
        wait "$STANDALONE_TOR_MONITOR_PID" 2>/dev/null || true
    fi
    STANDALONE_TOR_MONITOR_PID=""

    if [[ -n "${STANDALONE_TOR_PID:-}" ]] && kill -0 "$STANDALONE_TOR_PID" 2>/dev/null; then
        kill "$STANDALONE_TOR_PID" 2>/dev/null || true
        wait "$STANDALONE_TOR_PID" 2>/dev/null || true
    fi
    STANDALONE_TOR_PID=""

    if [[ -n "${STANDALONE_GUARD_PID:-}" ]] && kill -0 "$STANDALONE_GUARD_PID" 2>/dev/null; then
        kill "$STANDALONE_GUARD_PID" 2>/dev/null || true
        wait "$STANDALONE_GUARD_PID" 2>/dev/null || true
    fi
    STANDALONE_GUARD_PID=""

    if [[ -n "${STANDALONE_RECEIVER_PID:-}" ]] && kill -0 "$STANDALONE_RECEIVER_PID" 2>/dev/null; then
        kill "$STANDALONE_RECEIVER_PID" 2>/dev/null || true
        wait "$STANDALONE_RECEIVER_PID" 2>/dev/null || true
    fi
    STANDALONE_RECEIVER_PID=""

    if [[ -n "${STANDALONE_TEMP_DIR:-}" ]]; then
        rm -rf "$STANDALONE_TEMP_DIR"
        STANDALONE_TEMP_DIR=""
    fi
}

abort_standalone_sender_smoke() {
    local status="${1:-130}"
    cleanup_standalone_sender_smoke
    exit "$status"
}

is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

parse_uint10() {
    printf '%d' "$((10#$1))"
}

is_standalone_sender_mode() {
    case "$SMOKE_KIND" in
        standalone-sender|standalone-sender-proxy-no-direct|standalone-sender-proxy-success|standalone-sender-real-tor-no-direct|standalone-sender-real-tor-onion-success|standalone-sender-real-tor-public-success|standalone-sender-real-tor-stable-public-success|standalone-sender-real-tor-stable-proxy-success)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_external_receiver_sender_mode() {
    [[ "$SMOKE_KIND" = "external-receiver-sender" ]]
}

is_foreign_sender_mode() {
    is_standalone_sender_mode || is_external_receiver_sender_mode
}

is_tor_standalone_sender_mode() {
    case "$SMOKE_KIND" in
        standalone-sender-real-tor-no-direct|standalone-sender-real-tor-onion-success|standalone-sender-real-tor-public-success|standalone-sender-real-tor-stable-public-success|standalone-sender-real-tor-stable-proxy-success)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_tor_public_standalone_sender_mode() {
    case "$SMOKE_KIND" in
        standalone-sender-real-tor-public-success|standalone-sender-real-tor-stable-public-success|standalone-sender-real-tor-stable-proxy-success)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_stable_public_endpoint_mode() {
    [[ "$SMOKE_KIND" = "standalone-sender-real-tor-stable-public-success" || "$SMOKE_KIND" = "standalone-sender-real-tor-stable-proxy-success" ]]
}

is_stable_public_proxy_endpoint_mode() {
    [[ "$SMOKE_KIND" = "standalone-sender-real-tor-stable-proxy-success" ]]
}

validate_public_candidate_host_value() {
    local name="$1"
    local host="${!name:-}"
    local normalized="${host,,}"
    normalized="${normalized%.}"

    if [[ -z "$normalized" || "$normalized" = *:* || "$normalized" = "localhost" || "$normalized" = *.localhost || "$normalized" = *.local || "$normalized" = *.onion ]]; then
        error "$name must be a public DNS name or public IPv4 address"
        return 1
    fi
    if [[ "$normalized" = "0.0.0.0" || "$normalized" = "::" || "$normalized" = "::1" || "$normalized" = fe80:* || "$normalized" = fc*:* || "$normalized" = fd*:* ]]; then
        error "$name must be a public DNS name or public IPv4 address"
        return 1
    fi
    if [[ "$normalized" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local oct1 oct2 oct3 oct4
        IFS=. read -r oct1 oct2 oct3 oct4 <<< "$normalized"
        if ! is_integer "$oct1" || ! is_integer "$oct2" || ! is_integer "$oct3" || ! is_integer "$oct4"; then
            error "$name must be a public DNS name or public IPv4 address"
            return 1
        fi
        oct1="$(parse_uint10 "$oct1")"
        oct2="$(parse_uint10 "$oct2")"
        oct3="$(parse_uint10 "$oct3")"
        oct4="$(parse_uint10 "$oct4")"
        if ((oct1 > 255 || oct2 > 255 || oct3 > 255 || oct4 > 255)); then
            error "$name must be a public DNS name or public IPv4 address"
            return 1
        fi
        if ((oct1 == 0 || oct1 == 10 || oct1 == 127 || oct1 >= 224)); then
            error "$name must be a public DNS name or public IPv4 address"
            return 1
        fi
        if ((oct1 == 100 && oct2 >= 64 && oct2 <= 127)); then
            error "$name must be a public DNS name or public IPv4 address"
            return 1
        fi
        if ((oct1 == 169 && oct2 == 254)); then
            error "$name must be a public DNS name or public IPv4 address"
            return 1
        fi
        if ((oct1 == 172 && oct2 >= 16 && oct2 <= 31)); then
            error "$name must be a public DNS name or public IPv4 address"
            return 1
        fi
        if ((oct1 == 192 && oct2 == 168)); then
            error "$name must be a public DNS name or public IPv4 address"
            return 1
        fi
        if ((oct1 == 192 && oct2 == 0 && (oct3 == 0 || oct3 == 2))); then
            error "$name must be a public DNS name or public IPv4 address"
            return 1
        fi
        if ((oct1 == 198 && (oct2 == 18 || oct2 == 19 || (oct2 == 51 && oct3 == 100)))); then
            error "$name must be a public DNS name or public IPv4 address"
            return 1
        fi
        if ((oct1 == 203 && oct2 == 0 && oct3 == 113)); then
            error "$name must be a public DNS name or public IPv4 address"
            return 1
        fi
    fi
    return 0
}

validate_stable_public_candidate_host_value() {
    local name="$1"
    local host="${!name:-}"
    local normalized="${host,,}"
    normalized="${normalized%.}"

    validate_public_candidate_host_value "$name" || return 1
    if [[ "$normalized" == *pinggy* || "$normalized" == *ngrok* || "$normalized" == *trycloudflare* || "$normalized" == *localhost.run* || "$normalized" == *serveo* || "$normalized" == *localtunnel* || "$normalized" == *bore.pub* ]]; then
        error "$name must not name an obvious temporary tunnel provider in stable endpoint mode"
        return 1
    fi
    return 0
}

normalize_sha256() {
    local value="${1,,}"
    value="${value//:/}"
    value="${value//-/}"
    value="${value// /}"
    printf '%s' "$value"
}

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        MISSING_ENV+=("$name")
    fi
}

validate_env() {
    MISSING_ENV=()
    require_env DINOX_REMOTE_JINGLE_S5B_SENDER_JID
    if is_external_receiver_sender_mode; then
        require_env DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD
        if [[ -z "${DINOX_REMOTE_JINGLE_S5B_RECEIVER_FULL_JID:-}" && -z "${DINOX_REMOTE_JINGLE_S5B_READY_FILE:-}" ]]; then
            MISSING_ENV+=("DINOX_REMOTE_JINGLE_S5B_RECEIVER_FULL_JID or DINOX_REMOTE_JINGLE_S5B_READY_FILE")
        fi
    else
        require_env DINOX_REMOTE_JINGLE_S5B_JID
        require_env DINOX_REMOTE_JINGLE_S5B_PASSWORD
    fi
    if [[ "$SMOKE_KIND" = "dinox-pair" || "$SMOKE_KIND" = "raw-sender" ]] || is_standalone_sender_mode; then
        require_env DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD
    else
        if ! is_external_receiver_sender_mode; then
            require_env DINOX_REMOTE_JINGLE_S5B_EXPECTED_NAME
            require_env DINOX_REMOTE_JINGLE_S5B_EXPECTED_SIZE
            require_env DINOX_REMOTE_JINGLE_S5B_EXPECTED_SHA256
        fi
    fi
    if is_tor_public_standalone_sender_mode; then
        require_env DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_HOST
        require_env DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT
    fi
    if is_stable_public_endpoint_mode; then
        require_env DINOX_REMOTE_JINGLE_S5B_STABLE_PUBLIC_ENDPOINT
    fi
    if is_stable_public_proxy_endpoint_mode; then
        require_env DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_JID
    fi

    if [[ "${#MISSING_ENV[@]}" -gt 0 ]]; then
        error "missing required environment:"
        printf '  %s\n' "${MISSING_ENV[@]}" >&2
        return 1
    fi

    if [[ "$SMOKE_KIND" != "dinox-pair" && "$SMOKE_KIND" != "raw-sender" ]] && ! is_foreign_sender_mode; then
        if ! is_integer "$DINOX_REMOTE_JINGLE_S5B_EXPECTED_SIZE"; then
            error "DINOX_REMOTE_JINGLE_S5B_EXPECTED_SIZE must be an integer between 0 and 4999999"
            return 1
        fi
        local expected_size
        expected_size="$(parse_uint10 "$DINOX_REMOTE_JINGLE_S5B_EXPECTED_SIZE")"
        if ((expected_size < 0 || expected_size >= 5000000)); then
            error "DINOX_REMOTE_JINGLE_S5B_EXPECTED_SIZE must be an integer between 0 and 4999999"
            return 1
        fi

        local normalized_sha256
        normalized_sha256="$(normalize_sha256 "$DINOX_REMOTE_JINGLE_S5B_EXPECTED_SHA256")"
        if [[ ! "$normalized_sha256" =~ ^[0-9a-f]{64}$ ]]; then
            error "DINOX_REMOTE_JINGLE_S5B_EXPECTED_SHA256 must be a SHA-256 hex digest"
            return 1
        fi
    fi

    if is_foreign_sender_mode && [[ -n "${DINOX_REMOTE_JINGLE_S5B_STANDALONE_PAYLOAD_FILE:-}" ]]; then
        if [[ ! -r "$DINOX_REMOTE_JINGLE_S5B_STANDALONE_PAYLOAD_FILE" ]]; then
            error "DINOX_REMOTE_JINGLE_S5B_STANDALONE_PAYLOAD_FILE must be readable"
            return 1
        fi
        local standalone_payload_size
        standalone_payload_size="$(wc -c < "$DINOX_REMOTE_JINGLE_S5B_STANDALONE_PAYLOAD_FILE" | tr -d '[:space:]')"
        if ! is_integer "$standalone_payload_size" || ((standalone_payload_size > STANDALONE_MAX_PAYLOAD_SIZE)); then
            error "DINOX_REMOTE_JINGLE_S5B_STANDALONE_PAYLOAD_FILE must be at most $STANDALONE_MAX_PAYLOAD_SIZE bytes"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_JINGLE_S5B_PORT:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_JINGLE_S5B_PORT"; then
            error "DINOX_REMOTE_JINGLE_S5B_PORT must be an integer between 1 and 65535"
            return 1
        fi
        local port
        port="$(parse_uint10 "$DINOX_REMOTE_JINGLE_S5B_PORT")"
        if ((port < 1 || port > 65535)); then
            error "DINOX_REMOTE_JINGLE_S5B_PORT must be an integer between 1 and 65535"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS"; then
            error "DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS must be an integer between 5 and 600"
            return 1
        fi
        local timeout
        timeout="$(parse_uint10 "$DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS")"
        if ((timeout < 5 || timeout > 600)); then
            error "DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS must be an integer between 5 and 600"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_JINGLE_S5B_READY_FILE:-}" ]]; then
        if is_external_receiver_sender_mode && [[ -z "${DINOX_REMOTE_JINGLE_S5B_RECEIVER_FULL_JID:-}" && ! -r "$DINOX_REMOTE_JINGLE_S5B_READY_FILE" ]]; then
            error "DINOX_REMOTE_JINGLE_S5B_READY_FILE must be readable when it is used as the external receiver source"
            return 1
        fi
        local ready_parent
        ready_parent="$(dirname "$DINOX_REMOTE_JINGLE_S5B_READY_FILE")"
        if ! is_external_receiver_sender_mode && [[ ! -d "$ready_parent" || ! -w "$ready_parent" ]]; then
            error "DINOX_REMOTE_JINGLE_S5B_READY_FILE parent must exist and be writable"
            return 1
        fi
    fi

    if is_external_receiver_sender_mode; then
        if [[ -n "${DINOX_REMOTE_JINGLE_S5B_STANDALONE_CANDIDATE_PORT:-}" ]]; then
            if ! is_integer "$DINOX_REMOTE_JINGLE_S5B_STANDALONE_CANDIDATE_PORT"; then
                error "DINOX_REMOTE_JINGLE_S5B_STANDALONE_CANDIDATE_PORT must be an integer between 1 and 65535"
                return 1
            fi
            local standalone_candidate_port
            standalone_candidate_port="$(parse_uint10 "$DINOX_REMOTE_JINGLE_S5B_STANDALONE_CANDIDATE_PORT")"
            if ((standalone_candidate_port < 1 || standalone_candidate_port > 65535)); then
                error "DINOX_REMOTE_JINGLE_S5B_STANDALONE_CANDIDATE_PORT must be an integer between 1 and 65535"
                return 1
            fi
        fi

        if [[ -n "${DINOX_REMOTE_JINGLE_S5B_STANDALONE_LISTEN_PORT:-}" ]]; then
            if ! is_integer "$DINOX_REMOTE_JINGLE_S5B_STANDALONE_LISTEN_PORT"; then
                error "DINOX_REMOTE_JINGLE_S5B_STANDALONE_LISTEN_PORT must be an integer between 1 and 65535"
                return 1
            fi
            local standalone_listen_port
            standalone_listen_port="$(parse_uint10 "$DINOX_REMOTE_JINGLE_S5B_STANDALONE_LISTEN_PORT")"
            if ((standalone_listen_port < 1 || standalone_listen_port > 65535)); then
                error "DINOX_REMOTE_JINGLE_S5B_STANDALONE_LISTEN_PORT must be an integer between 1 and 65535"
                return 1
            fi
        fi
    fi

    if [[ -n "${DINOX_REMOTE_JINGLE_S5B_TOR_BOOTSTRAP_TIMEOUT_SECONDS:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_JINGLE_S5B_TOR_BOOTSTRAP_TIMEOUT_SECONDS"; then
            error "DINOX_REMOTE_JINGLE_S5B_TOR_BOOTSTRAP_TIMEOUT_SECONDS must be an integer between 5 and 300"
            return 1
        fi
        local tor_bootstrap_timeout
        tor_bootstrap_timeout="$(parse_uint10 "$DINOX_REMOTE_JINGLE_S5B_TOR_BOOTSTRAP_TIMEOUT_SECONDS")"
        if ((tor_bootstrap_timeout < 5 || tor_bootstrap_timeout > 300)); then
            error "DINOX_REMOTE_JINGLE_S5B_TOR_BOOTSTRAP_TIMEOUT_SECONDS must be an integer between 5 and 300"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_JINGLE_S5B_REQUIRE_TOR_REJECT_LOG:-}" && "$DINOX_REMOTE_JINGLE_S5B_REQUIRE_TOR_REJECT_LOG" != "0" && "$DINOX_REMOTE_JINGLE_S5B_REQUIRE_TOR_REJECT_LOG" != "1" ]]; then
        error "DINOX_REMOTE_JINGLE_S5B_REQUIRE_TOR_REJECT_LOG must be 0 or 1"
        return 1
    fi

    if [[ -n "${DINOX_REMOTE_JINGLE_S5B_ONION_VIRTUAL_PORT:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_JINGLE_S5B_ONION_VIRTUAL_PORT"; then
            error "DINOX_REMOTE_JINGLE_S5B_ONION_VIRTUAL_PORT must be an integer between 1 and 65535"
            return 1
        fi
        local onion_virtual_port
        onion_virtual_port="$(parse_uint10 "$DINOX_REMOTE_JINGLE_S5B_ONION_VIRTUAL_PORT")"
        if ((onion_virtual_port < 1 || onion_virtual_port > 65535)); then
            error "DINOX_REMOTE_JINGLE_S5B_ONION_VIRTUAL_PORT must be an integer between 1 and 65535"
            return 1
        fi
    fi

    if is_stable_public_endpoint_mode; then
        if [[ "$DINOX_REMOTE_JINGLE_S5B_STABLE_PUBLIC_ENDPOINT" != "1" ]]; then
            error "DINOX_REMOTE_JINGLE_S5B_STABLE_PUBLIC_ENDPOINT must be 1 for the stable public endpoint gate"
            return 1
        fi
        validate_stable_public_candidate_host_value DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_HOST
        if is_stable_public_proxy_endpoint_mode && [[ "$DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_JID" == */* ]]; then
            error "DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_JID must be a bare proxy service JID"
            return 1
        fi
    elif is_tor_public_standalone_sender_mode; then
        validate_public_candidate_host_value DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_HOST
    fi

    if [[ -n "${DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT"; then
            error "DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT must be an integer between 1 and 65535"
            return 1
        fi
        local public_candidate_port
        public_candidate_port="$(parse_uint10 "$DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT")"
        if ((public_candidate_port < 1 || public_candidate_port > 65535)); then
            error "DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT must be an integer between 1 and 65535"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_PORT:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_PORT"; then
            error "DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_PORT must be an integer between 1 and 65535"
            return 1
        fi
        local public_listen_port
        public_listen_port="$(parse_uint10 "$DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_PORT")"
        if ((public_listen_port < 1 || public_listen_port > 65535)); then
            error "DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_PORT must be an integer between 1 and 65535"
            return 1
        fi
    fi

    if is_stable_public_endpoint_mode; then
        if is_stable_public_proxy_endpoint_mode; then
            if [[ -n "${DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_HOST:-}" || -n "${DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_PORT:-}" ]]; then
                error "stable public proxy mode must not set DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_HOST or DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_PORT"
                return 1
            fi
        elif [[ -n "${DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_PORT:-}" ]]; then
            local stable_candidate_port
            local stable_listen_port
            stable_candidate_port="$(parse_uint10 "$DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT")"
            stable_listen_port="$(parse_uint10 "$DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_PORT")"
            if [[ "$stable_listen_port" != "$stable_candidate_port" ]]; then
                error "stable public endpoint mode requires the local listen port to match DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT"
                return 1
            fi
        fi
        if ! is_stable_public_proxy_endpoint_mode && [[ -n "${DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_HOST:-}" ]]; then
            local stable_listen_host="${DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_HOST,,}"
            local stable_candidate_host="${DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_HOST,,}"
            stable_listen_host="${stable_listen_host%.}"
            stable_candidate_host="${stable_candidate_host%.}"
            if [[ "$stable_listen_host" != "0.0.0.0" && "$stable_listen_host" != "$stable_candidate_host" ]]; then
                error "stable public endpoint mode requires DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_HOST to be unset, 0.0.0.0 or the advertised public candidate host"
                return 1
            fi
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
    local msys2_arg_conv_excl="${MSYS2_ARG_CONV_EXCL:-}"
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
    if [[ -z "$msys2_arg_conv_excl" ]]; then
        msys2_arg_conv_excl="/RemoteJingleS5bSmoke"
    elif [[ "$msys2_arg_conv_excl" != "*" && ";$msys2_arg_conv_excl;" != *";/RemoteJingleS5bSmoke;"* ]]; then
        msys2_arg_conv_excl="/RemoteJingleS5bSmoke;$msys2_arg_conv_excl"
    fi
    env \
        PATH="$path_value" \
        LD_LIBRARY_PATH="$ld_library_path_value" \
        MSYS2_ARG_CONV_EXCL="$msys2_arg_conv_excl" \
        "$@"
}

compile_test_target() {
    env \
        -u DINOX_REMOTE_JINGLE_S5B_JID \
        -u DINOX_REMOTE_JINGLE_S5B_PASSWORD \
        -u DINOX_REMOTE_JINGLE_S5B_SENDER_JID \
        -u DINOX_REMOTE_JINGLE_S5B_EXPECTED_NAME \
        -u DINOX_REMOTE_JINGLE_S5B_EXPECTED_SIZE \
        -u DINOX_REMOTE_JINGLE_S5B_EXPECTED_SHA256 \
        -u DINOX_REMOTE_JINGLE_S5B_SENDER_PASSWORD \
        -u DINOX_REMOTE_JINGLE_S5B_HOST \
        -u DINOX_REMOTE_JINGLE_S5B_PORT \
        -u DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS \
        -u DINOX_REMOTE_JINGLE_S5B_READY_FILE \
        -u DINOX_REMOTE_JINGLE_S5B_PAIR_NAME \
        -u DINOX_REMOTE_JINGLE_S5B_RAW_NAME \
        -u DINOX_REMOTE_JINGLE_S5B_STANDALONE_NAME \
        -u DINOX_REMOTE_JINGLE_S5B_STANDALONE_PAYLOAD_FILE \
        -u DINOX_REMOTE_JINGLE_S5B_STANDALONE_CANDIDATE_HOST \
        -u DINOX_REMOTE_JINGLE_S5B_STANDALONE_CANDIDATE_PORT \
        -u DINOX_REMOTE_JINGLE_S5B_STANDALONE_LISTEN_HOST \
        -u DINOX_REMOTE_JINGLE_S5B_STANDALONE_LISTEN_PORT \
        -u DINOX_REMOTE_JINGLE_S5B_RECEIVER_FULL_JID \
        -u DINOX_REMOTE_JINGLE_S5B_PAYLOAD_FILE \
        -u DINOX_REMOTE_JINGLE_S5B_SMOKE \
        -u DINOX_REMOTE_JINGLE_S5B_DINOX_PAIR \
        -u DINOX_REMOTE_JINGLE_S5B_RAW \
        -u DINOX_REMOTE_JINGLE_S5B_PROXY_NO_DIRECT \
        -u DINOX_REMOTE_JINGLE_S5B_RECEIVER_PROXY_TYPE \
        -u DINOX_REMOTE_JINGLE_S5B_RECEIVER_PROXY_HOST \
        -u DINOX_REMOTE_JINGLE_S5B_RECEIVER_PROXY_PORT \
        -u DINOX_REMOTE_JINGLE_S5B_TOR_PATH \
        -u DINOX_REMOTE_JINGLE_S5B_TOR_BOOTSTRAP_TIMEOUT_SECONDS \
        -u DINOX_REMOTE_JINGLE_S5B_REQUIRE_TOR_REJECT_LOG \
        -u DINOX_REMOTE_JINGLE_S5B_ONION_VIRTUAL_PORT \
        -u DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_JID \
        -u DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_HOST \
        -u DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT \
        -u DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_HOST \
        -u DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_PORT \
        -u DINOX_REMOTE_JINGLE_S5B_STABLE_PUBLIC_ENDPOINT \
        meson compile -C "$BUILD_DIR" libdino/libdino-test
}

validate_standalone_sender_tool() {
    python3 "$STANDALONE_SENDER" --self-test
    if [[ "$SMOKE_KIND" = "standalone-sender-proxy-no-direct" || "$SMOKE_KIND" = "standalone-sender-proxy-success" ]]; then
        python3 "$GUARD_PROXY" --self-test
    fi
    if is_tor_standalone_sender_mode; then
        validate_tor_tool
    fi
}

validate_tor_tool() {
    local tor_path="${DINOX_REMOTE_JINGLE_S5B_TOR_PATH:-tor}"
    if [[ "$tor_path" = */* ]]; then
        if [[ ! -x "$tor_path" ]]; then
            error "DINOX_REMOTE_JINGLE_S5B_TOR_PATH is not executable: $tor_path"
            return 1
        fi
    elif ! command -v "$tor_path" >/dev/null 2>&1; then
        error "tor executable not found; set DINOX_REMOTE_JINGLE_S5B_TOR_PATH"
        return 1
    fi
}

tor_config_path() {
    local path="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$path"
    else
        printf '%s\n' "$path"
    fi
}

read_ready_value() {
    local ready_file="$1"
    local key="$2"
    awk -F= -v key="$key" '$1 == key { print $2; exit }' "$ready_file"
}

guard_reject_matches_candidate() {
    local reject_file="$1"
    local candidate_host="$2"
    local candidate_port="$3"
    awk -v host="$candidate_host" -v port="$candidate_port" '
        {
            matched_host = 0
            matched_port = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "host=" host) matched_host = 1
                if ($i == "port=" port) matched_port = 1
            }
            if (matched_host && matched_port) found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$reject_file"
}

guard_connect_matches_candidate() {
    local connect_file="$1"
    local candidate_host="$2"
    local candidate_port="$3"
    awk -v host="$candidate_host" -v port="$candidate_port" '
        {
            matched_host = 0
            matched_port = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "host=" host) matched_host = 1
                if ($i == "port=" port) matched_port = 1
            }
            if (matched_host && matched_port) found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$connect_file"
}

pick_local_port() {
    python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

wait_for_tor_bootstrap() {
    local tor_log="$1"
    local timeout="$2"
    local deadline=$((SECONDS + timeout))
    while true; do
        if [[ -s "$tor_log" ]] && grep -q "Bootstrapped 100% (done)" "$tor_log"; then
            return 0
        fi
        if [[ -n "${STANDALONE_TOR_PID:-}" ]] && ! kill -0 "$STANDALONE_TOR_PID" 2>/dev/null; then
            return 1
        fi
        if ((SECONDS >= deadline)); then
            return 1
        fi
        sleep 0.2
    done
}

wait_for_tor_private_reject() {
    local tor_log="$1"
    local deadline=$((SECONDS + 5))
    while true; do
        if [[ -s "$tor_log" ]] && grep -q "Rejecting SOCKS request for anonymous connection to private address" "$tor_log"; then
            return 0
        fi
        if ((SECONDS >= deadline)); then
            return 1
        fi
        sleep 0.2
    done
}

wait_for_tor_hidden_service_hostname() {
    local hostname_file="$1"
    local timeout="$2"
    local deadline=$((SECONDS + timeout))
    while true; do
        if [[ -s "$hostname_file" ]]; then
            local detected_onion_host
            detected_onion_host="$(tr -d '[:space:]' < "$hostname_file")"
            if [[ "$detected_onion_host" = *.onion ]]; then
                printf '%s\n' "$detected_onion_host"
                return 0
            fi
        fi
        if [[ -n "${STANDALONE_TOR_PID:-}" ]] && ! kill -0 "$STANDALONE_TOR_PID" 2>/dev/null; then
            return 1
        fi
        if ((SECONDS >= deadline)); then
            return 1
        fi
        sleep 0.2
    done
}

start_tor_socks_for_standalone_smoke() {
    local temp_dir="$1"
    local tor_host_var="$2"
    local tor_port_var="$3"
    local tor_log_var="$4"
    local tor_control_host_var="${5:-}"
    local tor_control_port_var="${6:-}"
    local tor_path="${DINOX_REMOTE_JINGLE_S5B_TOR_PATH:-tor}"
    local tor_bootstrap_timeout="${DINOX_REMOTE_JINGLE_S5B_TOR_BOOTSTRAP_TIMEOUT_SECONDS:-180}"
    local tor_dir="$temp_dir/tor"
    local tor_log_path="$temp_dir/tor.log"
    local tor_stdout_path="$temp_dir/tor.stdout"
    local torrc="$temp_dir/torrc"
    local tor_config_dir
    local tor_config_log_path
    local selected_tor_port
    local selected_tor_control_port

    validate_tor_tool
    mkdir -p "$tor_dir"
    tor_config_dir="$(tor_config_path "$tor_dir")"
    tor_config_log_path="$(tor_config_path "$tor_log_path")"
    selected_tor_port="$(pick_local_port)"
    selected_tor_control_port="$(pick_local_port)"
    cat > "$torrc" <<EOF
DataDirectory $tor_config_dir
SocksPort 127.0.0.1:$selected_tor_port
ControlPort 127.0.0.1:$selected_tor_control_port
CookieAuthentication 0
ClientOnly 1
AvoidDiskWrites 1
Log notice file $tor_config_log_path
EOF
    "$tor_path" -f "$torrc" > "$tor_stdout_path" 2>&1 &
    STANDALONE_TOR_PID="$!"

    if ! wait_for_tor_bootstrap "$tor_log_path" "$tor_bootstrap_timeout"; then
        error "timed out waiting for local Tor SOCKS bootstrap"
        [[ -f "$tor_stdout_path" ]] && cat "$tor_stdout_path" >&2
        [[ -f "$tor_log_path" ]] && cat "$tor_log_path" >&2
        return 1
    fi

    printf -v "$tor_host_var" '%s' "127.0.0.1"
    printf -v "$tor_port_var" '%s' "$selected_tor_port"
    printf -v "$tor_log_var" '%s' "$tor_log_path"
    if [[ -n "$tor_control_host_var" ]]; then
        printf -v "$tor_control_host_var" '%s' "127.0.0.1"
    fi
    if [[ -n "$tor_control_port_var" ]]; then
        printf -v "$tor_control_port_var" '%s' "$selected_tor_control_port"
    fi
}

start_tor_stream_monitor_for_standalone_smoke() {
    local control_host="$1"
    local control_port="$2"
    local target_host="$3"
    local target_port="$4"
    local timeout="$5"
    local matched_file="$6"
    local monitor_log="$7"

    python3 - "$control_host" "$control_port" "$target_host" "$target_port" "$timeout" "$matched_file" > "$monitor_log" 2>&1 <<'PY' &
import socket
import os
import sys
import time

control_host = sys.argv[1]
control_port = int(sys.argv[2])
target_host = sys.argv[3].lower().rstrip(".")
target_port = str(int(sys.argv[4]))
timeout = int(sys.argv[5])
matched_file = sys.argv[6]
target = f"{target_host}:{target_port}"


def read_response(handle):
    lines = []
    while True:
        line = handle.readline()
        if not line:
            raise RuntimeError("Tor control port closed")
        decoded = line.decode("utf-8", "replace").strip()
        lines.append(decoded)
        if decoded.startswith("250 ") or decoded == "250 OK":
            return lines
        if len(decoded) >= 4 and decoded[3:4] == " " and not decoded.startswith("250"):
            raise RuntimeError("Tor control command failed: " + decoded)


deadline = time.monotonic() + timeout
with socket.create_connection((control_host, control_port), timeout=timeout) as sock:
    sock.settimeout(1.0)
    handle = sock.makefile("rwb", buffering=0)
    handle.write(b"AUTHENTICATE\r\n")
    read_response(handle)
    handle.write(b"SETEVENTS STREAM\r\n")
    read_response(handle)
    buffer = b""
    while time.monotonic() < deadline:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            raise RuntimeError("Tor control port closed while monitoring streams")
        buffer += chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            decoded = line.decode("utf-8", "replace").strip()
            if not decoded.startswith("650 STREAM "):
                continue
            print(decoded, flush=True)
            fields = decoded.split()
            if len(fields) < 6:
                continue
            status = fields[3]
            stream_target = fields[5].lower()
            stream_host, separator, stream_port = stream_target.rpartition(":")
            if separator:
                stream_target = f"{stream_host.rstrip('.')}:{stream_port}"
            else:
                stream_target = stream_target.rstrip(".")
            if stream_target == target and status in {"SENTCONNECT", "SUCCEEDED"}:
                tmp_path = matched_file + ".tmp"
                with open(tmp_path, "w", encoding="utf-8") as output:
                    output.write(f"status={status}\n")
                    output.write(f"target={target}\n")
                os.replace(tmp_path, matched_file)
                sys.exit(0)

raise TimeoutError(f"Tor stream monitor did not observe target {target}")
PY
    STANDALONE_TOR_MONITOR_PID="$!"
}

wait_for_tor_public_stream_match() {
    local matched_file="$1"
    local monitor_log="$2"
    local timeout="$3"
    local deadline=$((SECONDS + timeout))
    while [[ ! -s "$matched_file" ]]; do
        if [[ -n "${STANDALONE_TOR_MONITOR_PID:-}" ]] && ! kill -0 "$STANDALONE_TOR_MONITOR_PID" 2>/dev/null; then
            error "Tor stream monitor exited before observing the public S5B candidate"
            [[ -f "$monitor_log" ]] && cat "$monitor_log" >&2
            return 1
        fi
        if ((SECONDS >= deadline)); then
            error "timed out waiting for Tor stream event for the public S5B candidate"
            [[ -f "$monitor_log" ]] && cat "$monitor_log" >&2
            return 1
        fi
        sleep 0.2
    done
}

run_external_receiver_sender() {
    validate_standalone_sender_tool

    local timeout="${DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS:-60}"
    STANDALONE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dinox-external-jingle-s5b-sender.XXXXXX")"
    trap cleanup_standalone_sender_smoke EXIT
    trap 'abort_standalone_sender_smoke 130' INT
    trap 'abort_standalone_sender_smoke 143' TERM

    local temp_dir="$STANDALONE_TEMP_DIR"
    local sender_log="$temp_dir/sender.log"
    local candidate_info_file="$temp_dir/sender-candidate"
    local payload_file="${DINOX_REMOTE_JINGLE_S5B_STANDALONE_PAYLOAD_FILE:-}"
    local expected_name="${DINOX_REMOTE_JINGLE_S5B_STANDALONE_NAME:-dinox-remote-jingle-s5b-external-receiver.txt}"
    local receiver_full="${DINOX_REMOTE_JINGLE_S5B_RECEIVER_FULL_JID:-}"
    local ready_file="${DINOX_REMOTE_JINGLE_S5B_READY_FILE:-}"

    if [[ -z "$payload_file" ]]; then
        payload_file="$temp_dir/payload.bin"
        printf 'DinoX remote Jingle S5B external receiver sender payload\n' > "$payload_file"
    fi

    local expected_size
    expected_size="$(wc -c < "$payload_file" | tr -d '[:space:]')"
    if ! is_integer "$expected_size" || ((expected_size > STANDALONE_MAX_PAYLOAD_SIZE)); then
        error "external receiver sender payload must be at most $STANDALONE_MAX_PAYLOAD_SIZE bytes"
        cleanup_standalone_sender_smoke
        trap - EXIT INT TERM
        return 1
    fi

    local expected_sha256
    expected_sha256="$(sha256sum "$payload_file" | awk '{print $1}')"

    local sender_args=(
        --run
        --payload "$payload_file"
        --name "$expected_name"
        --timeout "$timeout"
        --candidate-info-file "$candidate_info_file"
    )
    if [[ -n "$receiver_full" ]]; then
        sender_args+=(--receiver-full-jid "$receiver_full")
    fi
    if [[ -n "${DINOX_REMOTE_JINGLE_S5B_STANDALONE_CANDIDATE_HOST:-}" ]]; then
        sender_args+=(--candidate-host "$DINOX_REMOTE_JINGLE_S5B_STANDALONE_CANDIDATE_HOST")
    fi
    if [[ -n "${DINOX_REMOTE_JINGLE_S5B_STANDALONE_CANDIDATE_PORT:-}" ]]; then
        sender_args+=(--candidate-port "$DINOX_REMOTE_JINGLE_S5B_STANDALONE_CANDIDATE_PORT")
    fi
    if [[ -n "${DINOX_REMOTE_JINGLE_S5B_STANDALONE_LISTEN_HOST:-}" ]]; then
        sender_args+=(--listen-host "$DINOX_REMOTE_JINGLE_S5B_STANDALONE_LISTEN_HOST")
    fi
    if [[ -n "${DINOX_REMOTE_JINGLE_S5B_STANDALONE_LISTEN_PORT:-}" ]]; then
        sender_args+=(--listen-port "$DINOX_REMOTE_JINGLE_S5B_STANDALONE_LISTEN_PORT")
    fi

    if ! DINOX_REMOTE_JINGLE_S5B_READY_FILE="$ready_file" python3 "$STANDALONE_SENDER" "${sender_args[@]}" > "$sender_log" 2>&1; then
        error "external receiver foreign sender failed"
        cat "$sender_log" >&2
        cleanup_standalone_sender_smoke
        trap - EXIT INT TERM
        return 1
    fi

    cat "$sender_log"
    echo "external_receiver_expected_name=$expected_name"
    echo "external_receiver_expected_size=$expected_size"
    echo "external_receiver_expected_sha256=$expected_sha256"
    if [[ -s "$candidate_info_file" ]]; then
        local candidate_host
        local candidate_port
        candidate_host="$(read_ready_value "$candidate_info_file" host)"
        candidate_port="$(read_ready_value "$candidate_info_file" port)"
        if [[ -n "$candidate_host" && -n "$candidate_port" ]]; then
            echo "external_receiver_sender_candidate=$candidate_host:$candidate_port"
        fi
    fi
    echo "remote-jingle-s5b-external-receiver-sender-ok"
    cleanup_standalone_sender_smoke
    trap - EXIT INT TERM
}

start_tor_hidden_service_for_standalone_smoke() {
    local temp_dir="$1"
    local target_port="$2"
    local virtual_port="$3"
    local tor_host_var="$4"
    local tor_port_var="$5"
    local tor_log_var="$6"
    local onion_host_var="$7"
    local tor_path="${DINOX_REMOTE_JINGLE_S5B_TOR_PATH:-tor}"
    local tor_bootstrap_timeout="${DINOX_REMOTE_JINGLE_S5B_TOR_BOOTSTRAP_TIMEOUT_SECONDS:-180}"
    local tor_root="$temp_dir/tor"
    local tor_data_dir="$tor_root/data"
    local hidden_service_dir="$tor_root/hidden-service"
    local tor_log_path="$temp_dir/tor.log"
    local tor_stdout_path="$temp_dir/tor.stdout"
    local torrc="$temp_dir/torrc"
    local tor_config_data_dir
    local tor_config_hidden_service_dir
    local tor_config_log_path
    local tor_port
    local detected_onion_host=""

    validate_tor_tool
    mkdir -p "$tor_data_dir" "$hidden_service_dir"
    chmod 700 "$tor_data_dir" "$hidden_service_dir"
    tor_config_data_dir="$(tor_config_path "$tor_data_dir")"
    tor_config_hidden_service_dir="$(tor_config_path "$hidden_service_dir")"
    tor_config_log_path="$(tor_config_path "$tor_log_path")"
    tor_port="$(pick_local_port)"
    cat > "$torrc" <<EOF
DataDirectory $tor_config_data_dir
SocksPort 127.0.0.1:$tor_port
ControlPort 0
CookieAuthentication 0
HiddenServiceDir $tor_config_hidden_service_dir
HiddenServicePort $virtual_port 127.0.0.1:$target_port
Log notice file $tor_config_log_path
EOF
    "$tor_path" -f "$torrc" > "$tor_stdout_path" 2>&1 &
    STANDALONE_TOR_PID="$!"

    if ! detected_onion_host="$(wait_for_tor_hidden_service_hostname "$hidden_service_dir/hostname" 30)"; then
        error "timed out waiting for local Tor hidden-service hostname"
        [[ -f "$tor_stdout_path" ]] && cat "$tor_stdout_path" >&2
        [[ -f "$tor_log_path" ]] && cat "$tor_log_path" >&2
        return 1
    fi

    if ! wait_for_tor_bootstrap "$tor_log_path" "$tor_bootstrap_timeout"; then
        error "timed out waiting for local Tor hidden-service bootstrap"
        [[ -f "$tor_stdout_path" ]] && cat "$tor_stdout_path" >&2
        [[ -f "$tor_log_path" ]] && cat "$tor_log_path" >&2
        return 1
    fi

    printf -v "$tor_host_var" '%s' "127.0.0.1"
    printf -v "$tor_port_var" '%s' "$tor_port"
    printf -v "$tor_log_var" '%s' "$tor_log_path"
    printf -v "$onion_host_var" '%s' "$detected_onion_host"
}

run_standalone_sender_smoke() {
    local test_binary="$BUILD_DIR/libdino/libdino-test"
    if [[ ! -x "$test_binary" ]]; then
        error "test binary not found after compile: $test_binary"
        return 1
    fi
    validate_standalone_sender_tool

    local timeout="${DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS:-60}"
    STANDALONE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dinox-foreign-jingle-s5b.XXXXXX")"
    trap cleanup_standalone_sender_smoke EXIT
    trap 'abort_standalone_sender_smoke 130' INT
    trap 'abort_standalone_sender_smoke 143' TERM

    local temp_dir="$STANDALONE_TEMP_DIR"
    local ready_file="$temp_dir/ready"
    local receiver_log="$temp_dir/receiver.log"
    local sender_log="$temp_dir/sender.log"
    local guard_ready_file="$temp_dir/guard-ready"
    local guard_reject_file="$temp_dir/guard-rejects.log"
    local guard_connect_file="$temp_dir/guard-connects.log"
    local guard_log="$temp_dir/guard.log"
    local candidate_info_file="$temp_dir/sender-candidate"
    local tor_public_stream_file="$temp_dir/tor-public-stream"
    local tor_stream_monitor_log="$temp_dir/tor-stream-monitor.log"
    local payload_file="${DINOX_REMOTE_JINGLE_S5B_STANDALONE_PAYLOAD_FILE:-}"
    local expected_name="${DINOX_REMOTE_JINGLE_S5B_STANDALONE_NAME:-dinox-remote-jingle-s5b-foreign.txt}"
    local receiver_pid=""
    local guard_host=""
    local guard_port=""
    local expect_no_direct=0
    local expect_proxy_success=0
    local expect_tor_no_direct=0
    local expect_tor_onion_success=0
    local expect_tor_public_success=0
    local use_receiver_proxy=0
    local test_path="$FOREIGN_TEST_PATH"
    local tor_log=""
    local tor_control_host=""
    local tor_control_port=""
    local onion_host=""
    local onion_virtual_port="${DINOX_REMOTE_JINGLE_S5B_ONION_VIRTUAL_PORT:-7777}"
    local onion_target_port=""
    local public_candidate_host="${DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_HOST:-}"
    local public_candidate_port="${DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_PORT:-}"
    local public_candidate_jid="${DINOX_REMOTE_JINGLE_S5B_PUBLIC_CANDIDATE_JID:-}"
    local public_listen_host="${DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_HOST:-0.0.0.0}"
    local public_listen_port="${DINOX_REMOTE_JINGLE_S5B_PUBLIC_LISTEN_PORT:-}"

    if [[ "$SMOKE_KIND" = "standalone-sender-proxy-no-direct" ]]; then
        expect_no_direct=1
        use_receiver_proxy=1
        test_path="$PROXY_NO_DIRECT_TEST_PATH"
    elif [[ "$SMOKE_KIND" = "standalone-sender-proxy-success" ]]; then
        expect_proxy_success=1
        use_receiver_proxy=1
    elif [[ "$SMOKE_KIND" = "standalone-sender-real-tor-no-direct" ]]; then
        expect_no_direct=1
        expect_tor_no_direct=1
        use_receiver_proxy=1
        test_path="$PROXY_NO_DIRECT_TEST_PATH"
    elif [[ "$SMOKE_KIND" = "standalone-sender-real-tor-onion-success" ]]; then
        expect_tor_onion_success=1
        use_receiver_proxy=1
    elif is_tor_public_standalone_sender_mode; then
        expect_tor_public_success=1
        use_receiver_proxy=1
    fi
    if ((expect_tor_onion_success || expect_tor_public_success)) && [[ -z "${DINOX_REMOTE_JINGLE_S5B_TIMEOUT_SECONDS:-}" ]]; then
        timeout=180
    fi

    if [[ -z "$payload_file" ]]; then
        payload_file="$temp_dir/payload.bin"
        printf 'DinoX remote Jingle S5B standalone foreign sender smoke payload\n' > "$payload_file"
    fi

    local expected_size
    expected_size="$(wc -c < "$payload_file" | tr -d '[:space:]')"
    if ! is_integer "$expected_size" || ((expected_size > STANDALONE_MAX_PAYLOAD_SIZE)); then
        error "standalone sender payload must be at most $STANDALONE_MAX_PAYLOAD_SIZE bytes"
        cleanup_standalone_sender_smoke
        trap - EXIT INT TERM
        return 1
    fi
    local expected_sha256
    expected_sha256="$(sha256sum "$payload_file" | awk '{print $1}')"

    if ((expect_tor_onion_success)); then
        onion_target_port="$(pick_local_port)"
        start_tor_hidden_service_for_standalone_smoke "$temp_dir" "$onion_target_port" "$onion_virtual_port" guard_host guard_port tor_log onion_host
    elif ((expect_tor_public_success)); then
        start_tor_socks_for_standalone_smoke "$temp_dir" guard_host guard_port tor_log tor_control_host tor_control_port
        if [[ -z "$tor_control_host" || -z "$tor_control_port" ]]; then
            error "local Tor control port was not exported for public-candidate monitoring"
            cleanup_standalone_sender_smoke
            trap - EXIT INT TERM
            return 1
        fi
        start_tor_stream_monitor_for_standalone_smoke "$tor_control_host" "$tor_control_port" "$public_candidate_host" "$public_candidate_port" "$timeout" "$tor_public_stream_file" "$tor_stream_monitor_log"
    elif ((expect_tor_no_direct)); then
        start_tor_socks_for_standalone_smoke "$temp_dir" guard_host guard_port tor_log
    elif ((expect_no_direct || expect_proxy_success)); then
        local guard_args=(
            --ready-file "$guard_ready_file"
            --reject-file "$guard_reject_file"
            --connect-file "$guard_connect_file"
        )
        if ((expect_proxy_success)); then
            guard_args+=(--allow-file "$candidate_info_file")
        fi
        python3 "$GUARD_PROXY" "${guard_args[@]}" > "$guard_log" 2>&1 &
        STANDALONE_GUARD_PID="$!"

        local guard_deadline=$((SECONDS + timeout))
        while [[ ! -s "$guard_ready_file" ]]; do
            if ! kill -0 "$STANDALONE_GUARD_PID" 2>/dev/null; then
                error "guard proxy exited before writing the ready file"
                cat "$guard_log" >&2
                cleanup_standalone_sender_smoke
                trap - EXIT INT TERM
                return 1
            fi
            if ((SECONDS >= guard_deadline)); then
                error "timed out waiting for guard proxy ready file"
                cat "$guard_log" >&2
                cleanup_standalone_sender_smoke
                trap - EXIT INT TERM
                return 1
            fi
            sleep 0.1
        done
        guard_host="$(read_ready_value "$guard_ready_file" host)"
        guard_port="$(read_ready_value "$guard_ready_file" port)"
        if [[ -z "$guard_host" || -z "$guard_port" ]] || ! is_integer "$guard_port"; then
            error "guard proxy ready file did not contain a usable host/port"
            cat "$guard_log" >&2
            cleanup_standalone_sender_smoke
            trap - EXIT INT TERM
            return 1
        fi
    fi

    local receiver_timeout=$((timeout * 3))
    local timeout_binary
    if ! timeout_binary="$(command -v timeout)"; then
        error "GNU timeout executable not found"
        cleanup_standalone_sender_smoke
        trap - EXIT INT TERM
        return 1
    fi
    local receiver_env=(
        DINOX_REMOTE_JINGLE_S5B_SMOKE=1
        DINOX_REMOTE_JINGLE_S5B_EXPECTED_NAME="$expected_name"
        DINOX_REMOTE_JINGLE_S5B_EXPECTED_SIZE="$expected_size"
        DINOX_REMOTE_JINGLE_S5B_EXPECTED_SHA256="$expected_sha256"
        DINOX_REMOTE_JINGLE_S5B_READY_FILE="$ready_file"
    )
    if ((use_receiver_proxy)); then
        local receiver_proxy_type=socks5
        if ((expect_tor_no_direct || expect_tor_onion_success || expect_tor_public_success)); then
            receiver_proxy_type=tor
        fi
        receiver_env+=(
            DINOX_REMOTE_JINGLE_S5B_RECEIVER_PROXY_TYPE="$receiver_proxy_type"
            DINOX_REMOTE_JINGLE_S5B_RECEIVER_PROXY_HOST="$guard_host"
            DINOX_REMOTE_JINGLE_S5B_RECEIVER_PROXY_PORT="$guard_port"
        )
        if ((expect_no_direct)); then
            receiver_env+=(DINOX_REMOTE_JINGLE_S5B_PROXY_NO_DIRECT=1)
        fi
    fi

    run_with_build_runtime_path "${receiver_env[@]}" "$timeout_binary" --kill-after=5s "${receiver_timeout}s" "$test_binary" -p "$test_path" > "$receiver_log" 2>&1 &
    receiver_pid="$!"
    STANDALONE_RECEIVER_PID="$receiver_pid"

    local deadline=$((SECONDS + timeout))
    while [[ ! -s "$ready_file" ]]; do
        if ! kill -0 "$receiver_pid" 2>/dev/null; then
            error "receiver smoke exited before writing the ready file"
            cat "$receiver_log" >&2
            wait "$receiver_pid" || true
            cleanup_standalone_sender_smoke
            trap - EXIT INT TERM
            return 1
        fi
        if ((SECONDS >= deadline)); then
            error "timed out waiting for receiver smoke ready file"
            cat "$receiver_log" >&2
            cleanup_standalone_sender_smoke
            trap - EXIT INT TERM
            return 1
        fi
        sleep 0.1
    done

    local sender_args=(
        --run
        --payload "$payload_file"
        --name "$expected_name"
        --timeout "$timeout"
    )
    if ((expect_no_direct)); then
        sender_args+=(
            --expect-no-connect
            --expect-no-direct-candidates
            --candidate-info-file "$candidate_info_file"
        )
    elif ((expect_proxy_success)); then
        sender_args+=(
            --expect-no-direct-candidates
            --candidate-info-file "$candidate_info_file"
        )
    elif ((expect_tor_onion_success)); then
        sender_args+=(
            --expect-no-direct-candidates
            --candidate-info-file "$candidate_info_file"
            --candidate-host "$onion_host"
            --candidate-port "$onion_virtual_port"
            --listen-port "$onion_target_port"
            --onion-warmup-socks-host "$guard_host"
            --onion-warmup-socks-port "$guard_port"
        )
    elif ((expect_tor_public_success)); then
        sender_args+=(
            --expect-no-direct-candidates
            --candidate-info-file "$candidate_info_file"
            --candidate-host "$public_candidate_host"
        )
        if is_stable_public_proxy_endpoint_mode; then
            sender_args+=(
                --candidate-type proxy
                --candidate-jid "$public_candidate_jid"
                --candidate-port "$public_candidate_port"
            )
        else
            sender_args+=(--listen-host "$public_listen_host")
            if [[ -n "$public_candidate_port" ]]; then
                sender_args+=(--candidate-port "$public_candidate_port")
            fi
            if [[ -n "$public_listen_port" ]]; then
                sender_args+=(--listen-port "$public_listen_port")
            elif [[ -n "$public_candidate_port" ]]; then
                sender_args+=(--listen-port "$public_candidate_port")
            fi
        fi
    fi

    if ! DINOX_REMOTE_JINGLE_S5B_READY_FILE="$ready_file" python3 "$STANDALONE_SENDER" "${sender_args[@]}" > "$sender_log" 2>&1; then
        error "standalone foreign sender failed"
        cat "$sender_log" >&2
        cat "$receiver_log" >&2
        if ((expect_tor_no_direct || expect_tor_onion_success || expect_tor_public_success)); then
            [[ -f "$tor_log" ]] && cat "$tor_log" >&2
            [[ -f "$tor_stream_monitor_log" ]] && cat "$tor_stream_monitor_log" >&2
        elif ((expect_no_direct || expect_proxy_success)); then
            cat "$guard_log" >&2
            [[ -f "$guard_reject_file" ]] && cat "$guard_reject_file" >&2
            [[ -f "$guard_connect_file" ]] && cat "$guard_connect_file" >&2
        fi
        cleanup_standalone_sender_smoke
        trap - EXIT INT TERM
        return 1
    fi

    if ! wait "$receiver_pid"; then
        error "receiver smoke failed after standalone sender finished"
        cat "$sender_log" >&2
        cat "$receiver_log" >&2
        if ((expect_tor_no_direct || expect_tor_onion_success || expect_tor_public_success)); then
            [[ -f "$tor_log" ]] && cat "$tor_log" >&2
            [[ -f "$tor_stream_monitor_log" ]] && cat "$tor_stream_monitor_log" >&2
        elif ((expect_no_direct || expect_proxy_success)); then
            cat "$guard_log" >&2
            [[ -f "$guard_reject_file" ]] && cat "$guard_reject_file" >&2
            [[ -f "$guard_connect_file" ]] && cat "$guard_connect_file" >&2
        fi
        cleanup_standalone_sender_smoke
        trap - EXIT INT TERM
        return 1
    fi
    receiver_pid=""
    STANDALONE_RECEIVER_PID=""

    if ((expect_tor_no_direct)); then
        if [[ "${DINOX_REMOTE_JINGLE_S5B_REQUIRE_TOR_REJECT_LOG:-0}" = "1" ]]; then
            if ! wait_for_tor_private_reject "$tor_log"; then
                error "Tor did not record rejection of the offered private direct S5B candidate"
                cat "$sender_log" >&2
                cat "$receiver_log" >&2
                [[ -f "$tor_log" ]] && cat "$tor_log" >&2
                [[ -f "$temp_dir/tor.stdout" ]] && cat "$temp_dir/tor.stdout" >&2
                cleanup_standalone_sender_smoke
                trap - EXIT INT TERM
                return 1
            fi
        fi
    elif ((expect_tor_public_success)); then
        local candidate_host
        local candidate_port
        local candidate_jid
        local candidate_type
        candidate_host="$(read_ready_value "$candidate_info_file" host)"
        candidate_port="$(read_ready_value "$candidate_info_file" port)"
        candidate_jid="$(read_ready_value "$candidate_info_file" jid)"
        candidate_type="$(read_ready_value "$candidate_info_file" type)"
        if [[ "$candidate_host" != "$public_candidate_host" || "$candidate_port" != "$public_candidate_port" ]]; then
            error "standalone sender did not advertise the configured public S5B candidate"
            cat "$sender_log" >&2
            cat "$receiver_log" >&2
            [[ -f "$tor_log" ]] && cat "$tor_log" >&2
            [[ -f "$tor_stream_monitor_log" ]] && cat "$tor_stream_monitor_log" >&2
            cleanup_standalone_sender_smoke
            trap - EXIT INT TERM
            return 1
        fi
        if is_stable_public_proxy_endpoint_mode; then
            if [[ "$candidate_type" != "proxy" || "$candidate_jid" != "$public_candidate_jid" ]]; then
                error "standalone sender did not advertise the configured public S5B proxy candidate"
                cat "$sender_log" >&2
                cat "$receiver_log" >&2
                [[ -f "$tor_log" ]] && cat "$tor_log" >&2
                [[ -f "$tor_stream_monitor_log" ]] && cat "$tor_stream_monitor_log" >&2
                cleanup_standalone_sender_smoke
                trap - EXIT INT TERM
                return 1
            fi
        elif [[ -n "$candidate_type" && "$candidate_type" != "direct" ]]; then
            error "standalone sender did not advertise a direct public S5B candidate"
            cat "$sender_log" >&2
            cat "$receiver_log" >&2
            [[ -f "$tor_log" ]] && cat "$tor_log" >&2
            [[ -f "$tor_stream_monitor_log" ]] && cat "$tor_stream_monitor_log" >&2
            cleanup_standalone_sender_smoke
            trap - EXIT INT TERM
            return 1
        fi
        if ! wait_for_tor_public_stream_match "$tor_public_stream_file" "$tor_stream_monitor_log" "$timeout"; then
            cat "$sender_log" >&2
            cat "$receiver_log" >&2
            [[ -f "$tor_log" ]] && cat "$tor_log" >&2
            cleanup_standalone_sender_smoke
            trap - EXIT INT TERM
            return 1
        fi
    elif ((expect_no_direct)); then
        if [[ ! -s "$guard_reject_file" ]]; then
            error "guard proxy did not record a rejected direct S5B CONNECT"
            cat "$sender_log" >&2
            cat "$receiver_log" >&2
            cat "$guard_log" >&2
            cleanup_standalone_sender_smoke
            trap - EXIT INT TERM
            return 1
        fi
        local candidate_host
        local candidate_port
        candidate_host="$(read_ready_value "$candidate_info_file" host)"
        candidate_port="$(read_ready_value "$candidate_info_file" port)"
        if [[ -z "$candidate_host" || -z "$candidate_port" ]] || ! is_integer "$candidate_port"; then
            error "standalone sender did not write a usable direct S5B candidate host/port"
            cat "$sender_log" >&2
            cat "$receiver_log" >&2
            cat "$guard_log" >&2
            cat "$guard_reject_file" >&2
            cleanup_standalone_sender_smoke
            trap - EXIT INT TERM
            return 1
        fi
        if ! guard_reject_matches_candidate "$guard_reject_file" "$candidate_host" "$candidate_port"; then
            error "guard proxy did not reject the offered direct S5B candidate $candidate_host:$candidate_port"
            cat "$sender_log" >&2
            cat "$receiver_log" >&2
            cat "$guard_log" >&2
            cat "$guard_reject_file" >&2
            cleanup_standalone_sender_smoke
            trap - EXIT INT TERM
            return 1
        fi
    elif ((expect_proxy_success)); then
        if [[ -s "$guard_reject_file" ]]; then
            error "guard proxy recorded an unexpected rejected CONNECT during proxy success smoke"
            cat "$sender_log" >&2
            cat "$receiver_log" >&2
            cat "$guard_log" >&2
            cat "$guard_reject_file" >&2
            cleanup_standalone_sender_smoke
            trap - EXIT INT TERM
            return 1
        fi
        if [[ ! -s "$guard_connect_file" ]]; then
            error "guard proxy did not record a successful CONNECT during proxy success smoke"
            cat "$sender_log" >&2
            cat "$receiver_log" >&2
            cat "$guard_log" >&2
            cleanup_standalone_sender_smoke
            trap - EXIT INT TERM
            return 1
        fi
        local candidate_host
        local candidate_port
        candidate_host="$(read_ready_value "$candidate_info_file" host)"
        candidate_port="$(read_ready_value "$candidate_info_file" port)"
        if [[ -z "$candidate_host" || -z "$candidate_port" ]] || ! is_integer "$candidate_port"; then
            error "standalone sender did not write a usable direct S5B candidate host/port"
            cat "$sender_log" >&2
            cat "$receiver_log" >&2
            cat "$guard_log" >&2
            cat "$guard_connect_file" >&2
            cleanup_standalone_sender_smoke
            trap - EXIT INT TERM
            return 1
        fi
        if ! guard_connect_matches_candidate "$guard_connect_file" "$candidate_host" "$candidate_port"; then
            error "guard proxy did not connect to the offered direct S5B candidate $candidate_host:$candidate_port"
            cat "$sender_log" >&2
            cat "$receiver_log" >&2
            cat "$guard_log" >&2
            cat "$guard_connect_file" >&2
            cleanup_standalone_sender_smoke
            trap - EXIT INT TERM
            return 1
        fi
    fi

    cat "$sender_log"
    if is_stable_public_proxy_endpoint_mode; then
        echo "remote-jingle-s5b-stable-public-proxy-ok"
    elif is_stable_public_endpoint_mode; then
        echo "remote-jingle-s5b-stable-public-endpoint-ok"
    fi
    cleanup_standalone_sender_smoke
    trap - EXIT INT TERM
}

run_smoke() {
    if is_external_receiver_sender_mode; then
        run_external_receiver_sender
        return
    fi

    local test_binary="$BUILD_DIR/libdino/libdino-test"
    if [[ ! -x "$test_binary" ]]; then
        error "test binary not found after compile: $test_binary"
        return 1
    fi

    case "$SMOKE_KIND" in
        dinox-pair)
            run_with_build_runtime_path DINOX_REMOTE_JINGLE_S5B_DINOX_PAIR=1 "$test_binary" -p "$PAIR_TEST_PATH"
            ;;
        raw-sender)
            run_with_build_runtime_path DINOX_REMOTE_JINGLE_S5B_RAW=1 "$test_binary" -p "$RAW_TEST_PATH"
            ;;
        standalone-sender)
            run_standalone_sender_smoke
            ;;
        standalone-sender-proxy-no-direct)
            run_standalone_sender_smoke
            ;;
        standalone-sender-proxy-success)
            run_standalone_sender_smoke
            ;;
        standalone-sender-real-tor-no-direct)
            run_standalone_sender_smoke
            ;;
        standalone-sender-real-tor-onion-success)
            run_standalone_sender_smoke
            ;;
        standalone-sender-real-tor-public-success)
            run_standalone_sender_smoke
            ;;
        standalone-sender-real-tor-stable-public-success)
            run_standalone_sender_smoke
            ;;
        standalone-sender-real-tor-stable-proxy-success)
            run_standalone_sender_smoke
            ;;
        *)
            run_with_build_runtime_path DINOX_REMOTE_JINGLE_S5B_SMOKE=1 "$test_binary" -p "$FOREIGN_TEST_PATH"
            ;;
    esac
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --preflight)
            MODE="preflight"
            shift
            ;;
        --dinox-pair)
            SMOKE_KIND="dinox-pair"
            shift
            ;;
        --raw-sender)
            SMOKE_KIND="raw-sender"
            shift
            ;;
        --standalone-sender)
            SMOKE_KIND="standalone-sender"
            shift
            ;;
        --standalone-sender-proxy-no-direct)
            SMOKE_KIND="standalone-sender-proxy-no-direct"
            shift
            ;;
        --standalone-sender-proxy-success)
            SMOKE_KIND="standalone-sender-proxy-success"
            shift
            ;;
        --standalone-sender-real-tor-no-direct)
            SMOKE_KIND="standalone-sender-real-tor-no-direct"
            shift
            ;;
        --standalone-sender-real-tor-onion-success)
            SMOKE_KIND="standalone-sender-real-tor-onion-success"
            shift
            ;;
        --standalone-sender-real-tor-public-success)
            SMOKE_KIND="standalone-sender-real-tor-public-success"
            shift
            ;;
        --standalone-sender-real-tor-stable-public-success)
            SMOKE_KIND="standalone-sender-real-tor-stable-public-success"
            shift
            ;;
        --standalone-sender-real-tor-stable-proxy-success)
            SMOKE_KIND="standalone-sender-real-tor-stable-proxy-success"
            shift
            ;;
        --external-receiver-sender)
            SMOKE_KIND="external-receiver-sender"
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
if ! is_external_receiver_sender_mode; then
    validate_build_dir
fi
if is_foreign_sender_mode; then
    validate_standalone_sender_tool
fi
if ! is_external_receiver_sender_mode; then
    compile_test_target
fi

if [[ "$MODE" = "preflight" ]]; then
    echo "Remote Jingle S5B smoke preflight OK"
    case "$SMOKE_KIND" in
        dinox-pair)
            echo "Focused test: $PAIR_TEST_PATH"
            ;;
        raw-sender)
            echo "Focused test: $RAW_TEST_PATH"
            ;;
        standalone-sender)
            echo "Focused test: $FOREIGN_TEST_PATH plus scripts/foreign-jingle-s5b-sender.py"
            ;;
        standalone-sender-proxy-no-direct)
            echo "Focused test: $PROXY_NO_DIRECT_TEST_PATH plus scripts/foreign-jingle-s5b-sender.py and scripts/remote-jingle-s5b-guard-proxy.py"
            ;;
        standalone-sender-proxy-success)
            echo "Focused test: $FOREIGN_TEST_PATH plus scripts/foreign-jingle-s5b-sender.py and scripts/remote-jingle-s5b-guard-proxy.py"
            ;;
        standalone-sender-real-tor-no-direct)
            echo "Focused test: $PROXY_NO_DIRECT_TEST_PATH plus scripts/foreign-jingle-s5b-sender.py and isolated local Tor SOCKS"
            ;;
        standalone-sender-real-tor-onion-success)
            echo "Focused test: $FOREIGN_TEST_PATH plus scripts/foreign-jingle-s5b-sender.py and isolated local Tor hidden-service S5B"
            ;;
        standalone-sender-real-tor-public-success)
            echo "Focused test: $FOREIGN_TEST_PATH plus scripts/foreign-jingle-s5b-sender.py, isolated local Tor SOCKS and a public S5B candidate"
            ;;
        standalone-sender-real-tor-stable-public-success)
            echo "Focused test: $FOREIGN_TEST_PATH plus scripts/foreign-jingle-s5b-sender.py, isolated local Tor SOCKS and a stable self-owned public S5B candidate"
            ;;
        standalone-sender-real-tor-stable-proxy-success)
            echo "Focused test: $FOREIGN_TEST_PATH plus scripts/foreign-jingle-s5b-sender.py, isolated local Tor SOCKS and a stable self-owned public XEP-0065 proxy candidate"
            ;;
        external-receiver-sender)
            echo "Focused sender: scripts/foreign-jingle-s5b-sender.py against an externally started receiver full JID"
            ;;
        *)
            echo "Focused test: $FOREIGN_TEST_PATH"
            ;;
    esac
    exit 0
fi

run_smoke
