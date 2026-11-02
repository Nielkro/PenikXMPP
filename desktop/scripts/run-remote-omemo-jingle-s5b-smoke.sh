#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
SEND_RECEIVE_TEST_PATH="/RemoteOmemoJingleS5bSmoke/omemo1_jingle_s5b_send_receive_env"
OMEMO2_SEND_RECEIVE_TEST_PATH="/RemoteOmemoJingleS5bSmoke/omemo2_jingle_s5b_send_receive_env"
SENDER_ONLY_TEST_PATH="/RemoteOmemoJingleS5bSmoke/omemo1_jingle_s5b_sender_env"
OMEMO2_SENDER_ONLY_TEST_PATH="/RemoteOmemoJingleS5bSmoke/omemo2_jingle_s5b_sender_env"
RECEIVE_ONLY_TEST_PATH="/RemoteOmemoJingleS5bSmoke/omemo1_jingle_s5b_receive_env"
OMEMO2_RECEIVE_ONLY_TEST_PATH="/RemoteOmemoJingleS5bSmoke/omemo2_jingle_s5b_receive_env"
OMEMO2_EXTERNAL_RECEIVER_V2_ONLY_TEST_PATH="/RemoteOmemoJingleS5bSmoke/omemo2_external_receiver_v2_only_guard_env"
TEST_PATH="$SEND_RECEIVE_TEST_PATH"
MODE="run"
DIST_RUNTIME=0
SENDER_ONLY=0
RECEIVE_ONLY=0
EXTERNAL_RECEIVER_V2_ONLY=0
OMEMO2=0
DIST_TEMP_DIR=""

usage() {
    cat <<EOF
Usage: $0 [--preflight] [--dist-runtime] [--sender-only] [--receive-only] [--external-receiver-v2-only] [--omemo2] [--build-dir DIR]

Runs the env-backed remote DinoX-to-DinoX OMEMO/JET Jingle S5B
file-send and receive smoke. This is a headless runtime proof: it uses two
real accounts, FileManager.send_file(), XEP-0234/XEP-0260 S5B, and the
production XEP-0391/JET envelope/cipher. The default is legacy OMEMO1;
--omemo2 selects the OMEMO2/JET send/receive or receive-only smoke.

Required environment:
  DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_JID
  DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PASSWORD
  DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_JID
  DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_PASSWORD

Optional environment:
  DINOX_REMOTE_OMEMO_JINGLE_S5B_HOST
  DINOX_REMOTE_OMEMO_JINGLE_S5B_PORT
  DINOX_REMOTE_OMEMO_JINGLE_S5B_TIMEOUT_SECONDS
  DINOX_REMOTE_OMEMO_JINGLE_S5B_FILE_NAME
  DINOX_REMOTE_OMEMO_JINGLE_S5B_PAYLOAD_TEXT
  DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_FULL_JID
  DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE
  DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE
  DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID
  DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_EXPECTS_V2_ONLY_RECEIVER
  DINOX_REMOTE_OMEMO_JINGLE_S5B_ALLOW_PEP_MUTATION
  DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_TYPE
  DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_HOST
  DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT
  DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_BIND_HOST
  DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PUBLIC_HOST
  DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PORT
  DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_NO_DIRECT_CANDIDATES
  DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE
  DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_HOST
  DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_PORT
  DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_JID
  DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_RECEIVER_NO_DIRECT_CANDIDATES
  DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_RECEIVER_SELECTED_SENDER_CANDIDATE

Options:
  --preflight       Validate required environment and local build target only.
  --dist-runtime    Run the test binary against packaged dist DLLs/plugins.
  --sender-only     Start only the DinoX sender side and send to an external receiver full JID.
  --receive-only    Start only the DinoX receiver side and wait for an external sender.
  --external-receiver-v2-only
                   Temporarily publish an empty OMEMO1 device list for an
                   externally running OMEMO2-capable receiver. Requires --omemo2,
                   receiver credentials, RECEIVER_OMEMO2_DEVICE_ID, READY_FILE,
                   DONE_FILE and DINOX_REMOTE_OMEMO_JINGLE_S5B_ALLOW_PEP_MUTATION=1;
                   restores the original OMEMO1 and targeted OMEMO2 device list before exit.
  --omemo2          Run the OMEMO2/JET send/receive or receive-only smoke.
  --build-dir       Use a non-default Meson build directory.
  --help            Show this help.

The runner never prints passwords, full JIDs, payload text, JET/OMEMO key
material or temp paths.
EOF
}

error() {
    echo "ERROR: $*" >&2
}

cleanup_dist_runtime() {
    if [[ -n "${DIST_TEMP_DIR:-}" ]]; then
        rm -rf "$DIST_TEMP_DIR"
        DIST_TEMP_DIR=""
    fi
}

trap cleanup_dist_runtime EXIT

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

validate_sanitized_literal_length() {
    local name="$1"
    local value="$2"
    if [[ -n "$value" && "${#value}" -lt 4 ]]; then
        error "$name must be at least 4 characters so failure-log sanitization can redact it safely"
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
    if (( ! EXTERNAL_RECEIVER_V2_ONLY )); then
        require_env DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_JID
    fi
    if (( ! RECEIVE_ONLY && ! EXTERNAL_RECEIVER_V2_ONLY )); then
        require_env DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PASSWORD
    fi
    require_env DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_JID
    if (( ! SENDER_ONLY || EXTERNAL_RECEIVER_V2_ONLY )); then
        require_env DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_PASSWORD
    fi
    if (( SENDER_ONLY )); then
        require_env DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_FULL_JID
    fi
    if (( EXTERNAL_RECEIVER_V2_ONLY )); then
        require_env DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE
        require_env DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE
        require_env DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID
        require_env DINOX_REMOTE_OMEMO_JINGLE_S5B_ALLOW_PEP_MUTATION
    fi

    if [[ "${#MISSING_ENV[@]}" -gt 0 ]]; then
        error "missing required environment:"
        printf '  %s\n' "${MISSING_ENV[@]}" >&2
        return 1
    fi

    if (( ! EXTERNAL_RECEIVER_V2_ONLY )); then
        validate_no_newline DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_JID "$DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_JID"
    fi
    if (( ! RECEIVE_ONLY && ! EXTERNAL_RECEIVER_V2_ONLY )); then
        validate_no_newline DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PASSWORD "$DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PASSWORD"
        validate_sanitized_literal_length DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PASSWORD "$DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PASSWORD"
    fi
    validate_no_newline DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_JID "$DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_JID"
    if (( ! SENDER_ONLY || EXTERNAL_RECEIVER_V2_ONLY )); then
        validate_no_newline DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_PASSWORD "$DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_PASSWORD"
        validate_sanitized_literal_length DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_PASSWORD "$DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_PASSWORD"
    fi
    if (( EXTERNAL_RECEIVER_V2_ONLY )); then
        validate_no_newline DINOX_REMOTE_OMEMO_JINGLE_S5B_ALLOW_PEP_MUTATION "$DINOX_REMOTE_OMEMO_JINGLE_S5B_ALLOW_PEP_MUTATION"
        if [[ "$DINOX_REMOTE_OMEMO_JINGLE_S5B_ALLOW_PEP_MUTATION" != "1" ]]; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_ALLOW_PEP_MUTATION=1 is required because --external-receiver-v2-only mutates receiver PEP state"
            return 1
        fi
    fi
    if (( ! EXTERNAL_RECEIVER_V2_ONLY )); then
        validate_account_jid DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_JID "$DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_JID"
    fi
    validate_account_jid DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_JID "$DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_JID"

    if (( SENDER_ONLY )); then
        validate_no_newline DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_FULL_JID "$DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_FULL_JID"
        local receiver_full_prefix="$DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_JID/"
        if [[ ! "$DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_FULL_JID" == "$receiver_full_prefix"* ||
                "$DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_FULL_JID" == "$receiver_full_prefix" ]]; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_FULL_JID must match receiver bare JID and include a resource"
            return 1
        fi
    fi

    if (( ! EXTERNAL_RECEIVER_V2_ONLY )) &&
            [[ "$DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_JID" == "$DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_JID" ]]; then
        error "sender and receiver accounts must be distinct"
        return 1
    fi

    for name in \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_HOST \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_PAYLOAD_TEXT \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_EXPECTS_V2_ONLY_RECEIVER \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_TYPE \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_HOST \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_BIND_HOST \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PUBLIC_HOST \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PORT \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_NO_DIRECT_CANDIDATES \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_HOST \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_PORT \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_JID \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_RECEIVER_NO_DIRECT_CANDIDATES \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_RECEIVER_SELECTED_SENDER_CANDIDATE
    do
        if [[ -n "${!name:-}" ]]; then
            validate_no_newline "$name" "${!name}"
        fi
    done
    if [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_PAYLOAD_TEXT:-}" ]]; then
        validate_sanitized_literal_length DINOX_REMOTE_OMEMO_JINGLE_S5B_PAYLOAD_TEXT "$DINOX_REMOTE_OMEMO_JINGLE_S5B_PAYLOAD_TEXT"
    fi

    if [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_FILE_NAME:-}" ]]; then
        validate_no_newline DINOX_REMOTE_OMEMO_JINGLE_S5B_FILE_NAME "$DINOX_REMOTE_OMEMO_JINGLE_S5B_FILE_NAME"
        validate_payload_name DINOX_REMOTE_OMEMO_JINGLE_S5B_FILE_NAME "$DINOX_REMOTE_OMEMO_JINGLE_S5B_FILE_NAME"
    fi

    if [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE:-}" ]]; then
        validate_no_newline DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE "$DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE"
        local ready_parent
        ready_parent="$(dirname "$DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE")"
        if [[ ! -d "$ready_parent" || ! -w "$ready_parent" ]]; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE parent must exist and be writable"
            return 1
        fi
    fi
    if [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE:-}" ]]; then
        validate_no_newline DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE "$DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE"
        local done_parent
        done_parent="$(dirname "$DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE")"
        if [[ ! -d "$done_parent" || ! -w "$done_parent" ]]; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE parent must exist and be writable"
            return 1
        fi
    fi
    if (( EXTERNAL_RECEIVER_V2_ONLY )) &&
            [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE:-}" && -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE:-}" ]]; then
        local ready_canonical done_canonical
        ready_canonical="$(readlink -m -- "$DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE")"
        done_canonical="$(readlink -m -- "$DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE")"
        if [[ "$ready_canonical" == "$done_canonical" ]]; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE and DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE must be different paths"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID"; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID must be a positive integer"
            return 1
        fi
        local receiver_device_id
        receiver_device_id="$(parse_uint10 "$DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID")"
        if ((receiver_device_id < 1 || receiver_device_id > 2147483647)); then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID must be between 1 and 2147483647"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_EXPECTS_V2_ONLY_RECEIVER:-}" ]]; then
        if [[ "$DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_EXPECTS_V2_ONLY_RECEIVER" != "0" &&
                "$DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_EXPECTS_V2_ONLY_RECEIVER" != "1" ]]; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_EXPECTS_V2_ONLY_RECEIVER must be 0 or 1"
            return 1
        fi
        if [[ "$DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_EXPECTS_V2_ONLY_RECEIVER" == "1" ]] &&
                (( ! SENDER_ONLY || ! OMEMO2 )); then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_EXPECTS_V2_ONLY_RECEIVER=1 requires --sender-only --omemo2"
            return 1
        fi
        if [[ "$DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_EXPECTS_V2_ONLY_RECEIVER" == "1" &&
                -z "${DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID:-}" ]]; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID is required when the sender expects a v2-only receiver"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_TYPE:-}" ||
          -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_HOST:-}" ||
          -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT:-}" ]]; then
        if (( ! SENDER_ONLY )); then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_* requires --sender-only"
            return 1
        fi
        local sender_proxy_type="${DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_TYPE:-none}"
        if [[ "$sender_proxy_type" != "none" && "$sender_proxy_type" != "socks5" && "$sender_proxy_type" != "tor" ]]; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_TYPE must be none, socks5 or tor"
            return 1
        fi
        if [[ "$sender_proxy_type" == "none" &&
              (-n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_HOST:-}" ||
               -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT:-}") ]]; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_HOST/PORT require a non-none sender proxy type"
            return 1
        fi
        if [[ "$sender_proxy_type" == "socks5" && -z "${DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_HOST:-}" ]]; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_HOST is required for sender socks5 proxy"
            return 1
        fi
        if [[ "$sender_proxy_type" != "none" && -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT:-}" ]]; then
            if ! is_integer "$DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT"; then
                error "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT must be an integer between 1 and 65535"
                return 1
            fi
            local sender_proxy_port
            sender_proxy_port="$(parse_uint10 "$DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT")"
            if ((sender_proxy_port < 1 || sender_proxy_port > 65535)); then
                error "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT must be an integer between 1 and 65535"
                return 1
            fi
        fi
        if [[ "$sender_proxy_type" == "socks5" && -z "${DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT:-}" ]]; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT is required for sender socks5 proxy"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_BIND_HOST:-}" ||
          -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PUBLIC_HOST:-}" ||
          -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PORT:-}" ]]; then
        if (( ! SENDER_ONLY )); then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_* requires --sender-only"
            return 1
        fi
        for name in \
            DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_BIND_HOST \
            DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PUBLIC_HOST \
            DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PORT
        do
            if [[ -z "${!name:-}" ]]; then
                error "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_* requires BIND_HOST, PUBLIC_HOST and PORT together"
                return 1
            fi
        done
        if [[ "${DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_TYPE:-none}" != "none" ]]; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_* requires sender proxy type none"
            return 1
        fi
        if [[ "${DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_NO_DIRECT_CANDIDATES:-0}" == "1" ]]; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_NO_DIRECT_CANDIDATES=1 conflicts with DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_*"
            return 1
        fi
        if ! is_integer "$DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PORT"; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PORT must be an integer between 1 and 65535"
            return 1
        fi
        local sender_direct_port
        sender_direct_port="$(parse_uint10 "$DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PORT")"
        if ((sender_direct_port < 1 || sender_direct_port > 65535)); then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PORT must be an integer between 1 and 65535"
            return 1
        fi
    fi

    local transport_expectation_set=0
    for name in \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_NO_DIRECT_CANDIDATES \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_RECEIVER_NO_DIRECT_CANDIDATES \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_RECEIVER_SELECTED_SENDER_CANDIDATE
    do
        if [[ -n "${!name:-}" ]]; then
            transport_expectation_set=1
            if [[ "${!name}" != "0" && "${!name}" != "1" ]]; then
                error "$name must be 0 or 1"
                return 1
            fi
        fi
    done
    local expected_sender_candidate_set=0
    for name in \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_HOST \
        DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_JID
    do
        if [[ -n "${!name:-}" ]]; then
            transport_expectation_set=1
            expected_sender_candidate_set=1
        fi
    done
    if [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE:-}" &&
          "$DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE" != "direct" &&
          "$DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE" != "proxy" &&
          "$DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE" != "assisted" &&
          "$DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE" != "tunnel" ]]; then
        error "DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE must be direct, proxy, assisted or tunnel"
        return 1
    fi
    if [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_PORT:-}" ]]; then
        transport_expectation_set=1
        expected_sender_candidate_set=1
        if ! is_integer "$DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_PORT"; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_PORT must be an integer between 1 and 65535"
            return 1
        fi
        local expected_candidate_port
        expected_candidate_port="$(parse_uint10 "$DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_PORT")"
        if ((expected_candidate_port < 1 || expected_candidate_port > 65535)); then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_PORT must be an integer between 1 and 65535"
            return 1
        fi
    fi
    if ((expected_sender_candidate_set)); then
        for name in \
            DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE \
            DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_HOST \
            DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_PORT \
            DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_JID
        do
            if [[ -z "${!name:-}" ]]; then
                error "DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_* requires TYPE, HOST, PORT and JID together"
                return 1
            fi
        done
    fi
    if ((transport_expectation_set && ! SENDER_ONLY)); then
        error "DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_* transport checks require --sender-only"
        return 1
    fi

    if [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_PORT:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_OMEMO_JINGLE_S5B_PORT"; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_PORT must be an integer between 1 and 65535"
            return 1
        fi
        local port
        port="$(parse_uint10 "$DINOX_REMOTE_OMEMO_JINGLE_S5B_PORT")"
        if ((port < 1 || port > 65535)); then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_PORT must be an integer between 1 and 65535"
            return 1
        fi
    fi

    if [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_TIMEOUT_SECONDS:-}" ]]; then
        if ! is_integer "$DINOX_REMOTE_OMEMO_JINGLE_S5B_TIMEOUT_SECONDS"; then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_TIMEOUT_SECONDS must be an integer between 5 and 900"
            return 1
        fi
        local timeout
        timeout="$(parse_uint10 "$DINOX_REMOTE_OMEMO_JINGLE_S5B_TIMEOUT_SECONDS")"
        if ((timeout < 5 || timeout > 900)); then
            error "DINOX_REMOTE_OMEMO_JINGLE_S5B_TIMEOUT_SECONDS must be an integer between 5 and 900"
            return 1
        fi
    fi
}

select_test_path() {
    if ((EXTERNAL_RECEIVER_V2_ONLY)); then
        TEST_PATH="$OMEMO2_EXTERNAL_RECEIVER_V2_ONLY_TEST_PATH"
    elif ((SENDER_ONLY && OMEMO2)); then
        TEST_PATH="$OMEMO2_SENDER_ONLY_TEST_PATH"
    elif ((SENDER_ONLY)); then
        TEST_PATH="$SENDER_ONLY_TEST_PATH"
    elif ((RECEIVE_ONLY && OMEMO2)); then
        TEST_PATH="$OMEMO2_RECEIVE_ONLY_TEST_PATH"
    elif ((RECEIVE_ONLY)); then
        TEST_PATH="$RECEIVE_ONLY_TEST_PATH"
    elif ((OMEMO2)); then
        TEST_PATH="$OMEMO2_SEND_RECEIVE_TEST_PATH"
    else
        TEST_PATH="$SEND_RECEIVE_TEST_PATH"
    fi
}

validate_build_dir() {
    if [[ ! -d "$BUILD_DIR" ]]; then
        error "build directory not found: $BUILD_DIR"
        error "run: meson setup build"
        return 1
    fi
}

append_remote_test_path_exclusion() {
    local value="${MSYS2_ARG_CONV_EXCL:-}"
    if [[ -z "$value" ]]; then
        printf '%s' "/RemoteOmemoJingleS5bSmoke"
    elif [[ "$value" == "*" || ";$value;" == *";/RemoteOmemoJingleS5bSmoke;"* ]]; then
        printf '%s' "$value"
    else
        printf '%s' "/RemoteOmemoJingleS5bSmoke;$value"
    fi
}

run_with_runtime_dirs() {
    local -a runtime_dirs=()
    while [[ "$#" -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then
            shift
            break
        fi
        runtime_dirs+=("$1")
        shift
    done
    local -a runtime_command=("$@")

    local path_value="${PATH:-}"
    local ld_library_path_value="${LD_LIBRARY_PATH:-}"
    local msys2_arg_conv_excl
    msys2_arg_conv_excl="$(append_remote_test_path_exclusion)"

    local dir
    for dir in "${runtime_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            path_value="$dir${path_value:+:$path_value}"
            ld_library_path_value="$dir${ld_library_path_value:+:$ld_library_path_value}"
        fi
    done
    env \
        PATH="$path_value" \
        LD_LIBRARY_PATH="$ld_library_path_value" \
        MSYS2_ARG_CONV_EXCL="$msys2_arg_conv_excl" \
        "${runtime_command[@]}"
}

run_with_build_runtime_path() {
    run_with_runtime_dirs \
        "$BUILD_DIR/libdino" \
        "$BUILD_DIR/xmpp-vala" \
        "$BUILD_DIR/qlite" \
        "$BUILD_DIR/crypto-vala" \
        "$BUILD_DIR/plugins/http-files" \
        "$BUILD_DIR/plugins/omemo" \
        "$BUILD_DIR/plugins/openpgp" \
        "$BUILD_DIR/plugins/ice" \
        -- "$@"
}

run_with_dist_runtime_path() {
    run_with_runtime_dirs \
        "$PROJECT_DIR/dist" \
        "$PROJECT_DIR/dist/bin" \
        "$PROJECT_DIR/dist/plugins" \
        -- "$@"
}

validate_dist_runtime() {
    local -a required_paths=(
        "$PROJECT_DIR/dist/dinox.exe"
        "$PROJECT_DIR/dist/libdino-0.dll"
        "$PROJECT_DIR/dist/libxmpp-vala-0.dll"
        "$PROJECT_DIR/dist/libqlite-0.dll"
        "$PROJECT_DIR/dist/libcrypto-vala-0.dll"
        "$PROJECT_DIR/dist/plugins/omemo.dll"
        "$PROJECT_DIR/dist/plugins/http-files.dll"
    )

    local path
    for path in "${required_paths[@]}"; do
        if [[ ! -f "$path" ]]; then
            error "packaged runtime path missing: $path"
            error "run the Windows dist builder before using --dist-runtime"
            return 1
        fi
    done
}

resolve_test_binary() {
    local base_path="$BUILD_DIR/plugins/omemo/omemo-test"
    if [[ -x "$base_path" ]]; then
        printf '%s' "$base_path"
        return 0
    fi
    if [[ -x "$base_path.exe" ]]; then
        printf '%s' "$base_path.exe"
        return 0
    fi
    error "test binary not found: $base_path"
    return 1
}

copy_test_binary_for_dist_runtime() {
    local source_binary
    source_binary="$(resolve_test_binary)"

    cleanup_dist_runtime
    DIST_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dinox-omemo-jingle-dist-runtime.XXXXXX")"
    local target_binary="$DIST_TEMP_DIR/omemo-test"
    if [[ "$source_binary" == *.exe ]]; then
        target_binary="$target_binary.exe"
    fi
    cp "$source_binary" "$target_binary"
    chmod +x "$target_binary"
    printf '%s' "$target_binary"
}

assert_dist_runtime_resolution() {
    local test_binary="$1"
    if ! command -v ldd >/dev/null 2>&1; then
        return 0
    fi

    local log_file
    local status=0
    log_file="$(mktemp "${TMPDIR:-/tmp}/dinox-remote-omemo-jingle-s5b-dist-ldd.XXXXXX.log")"
    PATH="${PROJECT_DIR}/dist:${PROJECT_DIR}/dist/bin:${PROJECT_DIR}/dist/plugins:${PATH:-}" \
        ldd "$test_binary" > "$log_file" 2>&1 || status="$?"

    if ((status != 0)); then
        error "could not inspect packaged dist runtime dependencies"
        sanitize_log "$log_file" >&2
        rm -f "$log_file"
        return "$status"
    fi
    if grep -q "not found" "$log_file"; then
        error "packaged dist runtime dependency resolution has missing DLLs"
        sanitize_log "$log_file" >&2
        rm -f "$log_file"
        return 1
    fi
    if grep -F "$BUILD_DIR/" "$log_file" >/dev/null; then
        error "packaged dist runtime dependency resolution still uses build-tree DLLs"
        sanitize_log "$log_file" >&2
        rm -f "$log_file"
        return 1
    fi

    local name
    for name in \
        libdino-0.dll \
        libxmpp-vala-0.dll \
        libqlite-0.dll \
        libcrypto-vala-0.dll \
        omemo.dll \
        http-files.dll
    do
        if ! grep -E "$name => .*/dist(/plugins)?/$name" "$log_file" >/dev/null; then
            error "packaged dist runtime dependency did not resolve from dist: $name"
            sanitize_log "$log_file" >&2
            rm -f "$log_file"
            return 1
        fi
    done
    rm -f "$log_file"
}

run_dist_runtime_skip_check() {
    local test_binary="$1"
    local log_file
    local status=0
    log_file="$(mktemp "${TMPDIR:-/tmp}/dinox-remote-omemo-jingle-s5b-dist-preflight.XXXXXX.log")"

    env \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SMOKE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_ONLY_SMOKE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVE_ONLY_SMOKE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_V2_ONLY_GUARD_SMOKE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_JID \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PASSWORD \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_JID \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_PASSWORD \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_HOST \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_PORT \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_TIMEOUT_SECONDS \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_FILE_NAME \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_PAYLOAD_TEXT \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_FULL_JID \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_EXPECTS_V2_ONLY_RECEIVER \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_ALLOW_PEP_MUTATION \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_TYPE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_HOST \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_BIND_HOST \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PUBLIC_HOST \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PORT \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_NO_DIRECT_CANDIDATES \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_HOST \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_PORT \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_JID \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_RECEIVER_NO_DIRECT_CANDIDATES \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_RECEIVER_SELECTED_SENDER_CANDIDATE \
        PATH="${PROJECT_DIR}/dist:${PROJECT_DIR}/dist/bin:${PROJECT_DIR}/dist/plugins:${PATH:-}" \
        LD_LIBRARY_PATH="${PROJECT_DIR}/dist:${PROJECT_DIR}/dist/bin:${PROJECT_DIR}/dist/plugins:${LD_LIBRARY_PATH:-}" \
        MSYS2_ARG_CONV_EXCL="$(append_remote_test_path_exclusion)" \
        "$test_binary" -p "$TEST_PATH" > "$log_file" 2>&1 || status="$?"

    if ((status != 0)); then
        error "packaged dist runtime preflight failed"
        sanitize_log "$log_file" >&2
        rm -f "$log_file"
        return "$status"
    fi
    rm -f "$log_file"
}

compile_test_target() {
    env \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SMOKE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_ONLY_SMOKE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVE_ONLY_SMOKE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_V2_ONLY_GUARD_SMOKE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_JID \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PASSWORD \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_JID \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_PASSWORD \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_HOST \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_PORT \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_TIMEOUT_SECONDS \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_FILE_NAME \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_PAYLOAD_TEXT \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_FULL_JID \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_OMEMO2_DEVICE_ID \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_EXPECTS_V2_ONLY_RECEIVER \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_ALLOW_PEP_MUTATION \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_TYPE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_HOST \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_PORT \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_BIND_HOST \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PUBLIC_HOST \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PORT \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_NO_DIRECT_CANDIDATES \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_TYPE \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_HOST \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_PORT \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_JID \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_RECEIVER_NO_DIRECT_CANDIDATES \
        -u DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_RECEIVER_SELECTED_SENDER_CANDIDATE \
        meson compile -C "$BUILD_DIR" plugins/omemo/omemo-test
}

sanitize_log() {
    local log_file="$1"
    perl -0pe '
        s{<\{eu\.siacs\.conversations\.axolotl\}:encrypted\b.*?</\{eu\.siacs\.conversations\.axolotl\}:encrypted>}{<omemo1-encrypted-redacted>}gs;
        s{<\{eu\.siacs\.conversations\.axolotl\}:bundle\b.*?</\{eu\.siacs\.conversations\.axolotl\}:bundle>}{<omemo1-bundle-redacted>}gs;
        s{<\{urn:xmpp:omemo:2\}:encrypted\b.*?</\{urn:xmpp:omemo:2\}:encrypted>}{<omemo2-encrypted-redacted>}gs;
        s{<\{urn:xmpp:omemo:2\}:bundle\b.*?</\{urn:xmpp:omemo:2\}:bundle>}{<omemo2-bundle-redacted>}gs;
        s{<encrypted\b[^>]*\Qeu.siacs.conversations.axolotl\E[^>]*>.*?</encrypted>}{<omemo1-encrypted-redacted>}gs;
        s{<bundle\b[^>]*\Qeu.siacs.conversations.axolotl\E[^>]*>.*?</bundle>}{<omemo1-bundle-redacted>}gs;
        s{<encrypted\b[^>]*\Qurn:xmpp:omemo:2\E[^>]*>.*?</encrypted>}{<omemo2-encrypted-redacted>}gs;
        s{<bundle\b[^>]*\Qurn:xmpp:omemo:2\E[^>]*>.*?</bundle>}{<omemo2-bundle-redacted>}gs;
        s{<security\b[^>]*\Qurn:xmpp:jingle:jet:0\E[^>]*>.*?</security>}{<jet-security-redacted>}gs;
        s{<\{urn:xmpp:jingle:jet:0\}:security\b.*?</\{urn:xmpp:jingle:jet:0\}:security>}{<jet-security-redacted>}gs;
        my @sensitive_names = qw(
            DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_JID
            DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PASSWORD
            DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_JID
            DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_PASSWORD
            DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVER_FULL_JID
            DINOX_REMOTE_OMEMO_JINGLE_S5B_HOST
            DINOX_REMOTE_OMEMO_JINGLE_S5B_FILE_NAME
            DINOX_REMOTE_OMEMO_JINGLE_S5B_PAYLOAD_TEXT
            DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE
            DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE
            DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_PROXY_HOST
            DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_BIND_HOST
            DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_DIRECT_PUBLIC_HOST
            DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_HOST
            DINOX_REMOTE_OMEMO_JINGLE_S5B_EXPECT_SENDER_CANDIDATE_JID
        );
        for my $name (sort { length($ENV{$b} // "") <=> length($ENV{$a} // "") } @sensitive_names) {
            my $value = $ENV{$name};
            next if !defined($value) || $value eq "";
            if (length($value) >= 4) {
                s/\Q$value\E/<$name>/g;
            } else {
                s/(\Q$name\E\s*=\s*)\Q$value\E/${1}<$name>/g;
                s/(\Q$name\E"?\s*:\s*"?)\Q$value\E/${1}<$name>/g;
            }
        }
        s{/(tmp|var/tmp)/[^\s<>"]*dinox-(remote-omemo-jingle-s5b|omemo-jingle-dist-runtime)[^\s<>"]*}{<remote-omemo-jingle-temp-path>}g;
        s/dinox-(remote-omemo-jingle-s5b-smoke|omemo-jingle-dist-runtime)-[0-9A-Za-z.:-]+/<generated-omemo-jingle-temp-name>/g;
    ' "$log_file"
}

run_smoke() {
    local test_binary
    test_binary="$(resolve_test_binary)"
    if ((DIST_RUNTIME)); then
        validate_dist_runtime
        test_binary="$(copy_test_binary_for_dist_runtime)"
        assert_dist_runtime_resolution "$test_binary"
    fi

    local log_file
    local status=0
    log_file="$(mktemp "${TMPDIR:-/tmp}/dinox-remote-omemo-jingle-s5b-smoke.XXXXXX.log")"
    local smoke_env="DINOX_REMOTE_OMEMO_JINGLE_S5B_SMOKE=1"
    local protocol_label="OMEMO1"
    local result_prefix="remote-omemo1"
    if ((OMEMO2)); then
        protocol_label="OMEMO2"
        result_prefix="remote-omemo2"
    fi
    if ((EXTERNAL_RECEIVER_V2_ONLY)); then
        smoke_env="DINOX_REMOTE_OMEMO_JINGLE_S5B_V2_ONLY_GUARD_SMOKE=1"
        rm -f -- "$DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE" "$DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE"
    elif ((RECEIVE_ONLY)); then
        smoke_env="DINOX_REMOTE_OMEMO_JINGLE_S5B_RECEIVE_ONLY_SMOKE=1"
        if [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE:-}" ]]; then
            rm -f -- "$DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE"
        fi
    elif ((SENDER_ONLY)); then
        smoke_env="DINOX_REMOTE_OMEMO_JINGLE_S5B_SENDER_ONLY_SMOKE=1"
    fi

    if ((DIST_RUNTIME)); then
        run_with_dist_runtime_path \
            "$smoke_env" \
            "$test_binary" -p "$TEST_PATH" > "$log_file" 2>&1 || status="$?"
    else
        run_with_build_runtime_path \
            "$smoke_env" \
            "$test_binary" -p "$TEST_PATH" > "$log_file" 2>&1 || status="$?"
    fi

    if ((status != 0)); then
        if ((EXTERNAL_RECEIVER_V2_ONLY)); then
            error "remote ${protocol_label}/JET Jingle S5B external receiver v2-only guard failed"
        elif ((RECEIVE_ONLY)); then
            error "remote ${protocol_label}/JET Jingle S5B receive-only smoke failed"
        elif ((SENDER_ONLY)); then
            error "remote ${protocol_label}/JET Jingle S5B sender-only smoke failed"
        else
            error "remote ${protocol_label}/JET Jingle S5B send/receive smoke failed"
        fi
        sanitize_log "$log_file" >&2
        rm -f "$log_file"
        return "$status"
    fi

    rm -f "$log_file"
    if ((EXTERNAL_RECEIVER_V2_ONLY)); then
        echo "${result_prefix}-jingle-s5b-external-receiver-v2-only-ok"
    elif ((RECEIVE_ONLY)); then
        echo "${result_prefix}-jingle-s5b-receive-ok"
    elif ((SENDER_ONLY)); then
        echo "${result_prefix}-jingle-s5b-external-receiver-sender-ok"
    elif ((DIST_RUNTIME)); then
        echo "${result_prefix}-jingle-s5b-dist-runtime-send-receive-ok"
    else
        echo "${result_prefix}-jingle-s5b-send-receive-ok"
    fi
}

clear_coordination_files_before_start() {
    if ((EXTERNAL_RECEIVER_V2_ONLY)) && [[ "$MODE" != "preflight" ]]; then
        rm -f -- "$DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE" "$DINOX_REMOTE_OMEMO_JINGLE_S5B_DONE_FILE"
    elif ((RECEIVE_ONLY)) && [[ "$MODE" != "preflight" ]] && [[ -n "${DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE:-}" ]]; then
        rm -f -- "$DINOX_REMOTE_OMEMO_JINGLE_S5B_READY_FILE"
    fi
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --preflight)
            MODE="preflight"
            shift
            ;;
        --dist-runtime)
            DIST_RUNTIME=1
            shift
            ;;
        --receive-only)
            RECEIVE_ONLY=1
            select_test_path
            shift
            ;;
        --external-receiver-v2-only)
            EXTERNAL_RECEIVER_V2_ONLY=1
            select_test_path
            shift
            ;;
        --sender-only|--external-receiver-sender)
            SENDER_ONLY=1
            select_test_path
            shift
            ;;
        --omemo2)
            OMEMO2=1
            select_test_path
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
            error "unknown option: $1"
            usage >&2
            exit 1
            ;;
    esac
done

if ((SENDER_ONLY + RECEIVE_ONLY + EXTERNAL_RECEIVER_V2_ONLY > 1)); then
    error "--sender-only, --receive-only and --external-receiver-v2-only are mutually exclusive"
    exit 1
fi

if ((EXTERNAL_RECEIVER_V2_ONLY && ! OMEMO2)); then
    error "--external-receiver-v2-only requires --omemo2"
    exit 1
fi

validate_build_dir
validate_env
clear_coordination_files_before_start
compile_test_target

if [[ "$MODE" == "preflight" ]]; then
    if ((DIST_RUNTIME)); then
        validate_dist_runtime
        dist_test_binary="$(copy_test_binary_for_dist_runtime)"
        assert_dist_runtime_resolution "$dist_test_binary"
        run_dist_runtime_skip_check "$dist_test_binary"
    fi
    echo "remote-omemo-jingle-s5b-preflight-ok"
    exit 0
fi

run_smoke
