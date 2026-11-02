#!/usr/bin/env bash
set -euo pipefail

# Reproducible Linux-only acceptance harness for the DinoX 2G call profile.
# It shapes both egress and ingress. Delay is split across both directions so
# the configured round-trip delay matches the value documented in the plan.

IFB_NAME="${DINOX_WEBRTC_TEST_IFB:-ifb-dinox}"

usage() {
    cat <<'EOF'
Usage:
  scripts/test-libwebrtc-constrained-network.sh describe PROFILE
  sudo scripts/test-libwebrtc-constrained-network.sh apply IFACE PROFILE
  sudo scripts/test-libwebrtc-constrained-network.sh clear IFACE
  sudo scripts/test-libwebrtc-constrained-network.sh status IFACE
  sudo scripts/test-libwebrtc-constrained-network.sh interrupt IFACE PROFILE SECONDS
  sudo -E scripts/test-libwebrtc-constrained-network.sh run IFACE PROFILE LOG -- COMMAND [ARG...]

Profiles:
  constrained  64 kbit/s each way, 400 ms RTT, 80 ms jitter, 3% loss
  harsh        40 kbit/s each way, 700 ms RTT, 150 ms jitter, 8% loss
  burst        64 kbit/s each way, 400 ms RTT, burst-loss model

The run form records tc/interface counters and the command output. Use it with
DINOX_GOOGLE_WEBRTC_CALL_DEBUG=1 so encoded bitrate, RTP counters, RTT, jitter
and packet-loss diagnostics are captured for a live Monal/Conversations call.
Only the network shaping runs as root. When invoked through sudo, COMMAND is
started again as the original desktop user; -E preserves the desktop/session
environment needed for audio, video and GTK.
EOF
}

fail() { echo "FAIL: $*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "this command requires root"; }
require_iface() { ip link show dev "$1" >/dev/null 2>&1 || fail "unknown interface: $1"; }

run_as_invoking_user() {
    if [[ ${EUID:-$(id -u)} -eq 0 && -n "${SUDO_UID:-}" && "${SUDO_UID}" != "0" ]]; then
        [[ "${SUDO_UID}" =~ ^[0-9]+$ && "${SUDO_GID:-}" =~ ^[0-9]+$ ]] \
            || fail "invalid sudo user identity"
        local invoking_user="${SUDO_USER:-}"
        local invoking_home=""
        if command -v getent >/dev/null 2>&1; then
            invoking_home="$(getent passwd "$SUDO_UID" | cut -d: -f6)"
        fi
        [[ -n "$invoking_user" && -n "$invoking_home" ]] \
            || fail "could not resolve the sudo invoking user"

        export HOME="$invoking_home"
        export USER="$invoking_user"
        export LOGNAME="$invoking_user"
        if [[ -z "${XDG_RUNTIME_DIR:-}" && -d "/run/user/$SUDO_UID" ]]; then
            export XDG_RUNTIME_DIR="/run/user/$SUDO_UID"
        fi
        if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "${XDG_RUNTIME_DIR:-}/bus" ]]; then
            export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
        fi

        if command -v setpriv >/dev/null 2>&1; then
            setpriv --reuid="$SUDO_UID" --regid="$SUDO_GID" --init-groups -- "$@"
        elif command -v runuser >/dev/null 2>&1; then
            runuser -u "$invoking_user" -- "$@"
        else
            fail "setpriv or runuser is required to start COMMAND without root privileges"
        fi
    else
        "$@"
    fi
}

profile_args() {
    case "$1" in
        constrained) printf '%s\n' "rate 64kbit delay 200ms 80ms distribution normal loss random 3% limit 1000" ;;
        harsh) printf '%s\n' "rate 40kbit delay 350ms 150ms distribution normal loss random 8% limit 1000" ;;
        burst) printf '%s\n' "rate 64kbit delay 200ms 80ms distribution normal loss gemodel 2% 35% 85% 1% limit 1000" ;;
        *) fail "unknown profile: $1" ;;
    esac
}

clear_shape() {
    local iface="$1"
    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc del dev "$iface" ingress 2>/dev/null || true
    tc qdisc del dev "$IFB_NAME" root 2>/dev/null || true
    ip link set dev "$IFB_NAME" down 2>/dev/null || true
    ip link del dev "$IFB_NAME" type ifb 2>/dev/null || true
}

apply_shape() {
    local iface="$1" profile="$2" args
    args="$(profile_args "$profile")"
    clear_shape "$iface"
    modprobe ifb numifbs=1 2>/dev/null || true
    ip link add "$IFB_NAME" type ifb 2>/dev/null || true
    ip link set dev "$IFB_NAME" up

    # shellcheck disable=SC2086
    tc qdisc replace dev "$iface" root handle 1: netem $args
    tc qdisc replace dev "$iface" handle ffff: ingress
    tc filter replace dev "$iface" parent ffff: protocol all pref 10 u32 \
        match u32 0 0 action mirred egress redirect dev "$IFB_NAME"
    # shellcheck disable=SC2086
    tc qdisc replace dev "$IFB_NAME" root handle 1: netem $args
}

show_status() {
    local iface="$1"
    echo "== $iface =="
    tc -s qdisc show dev "$iface"
    echo "== $IFB_NAME =="
    tc -s qdisc show dev "$IFB_NAME" 2>/dev/null || true
    echo "== interface counters =="
    ip -s link show dev "$iface"
    ip -s link show dev "$IFB_NAME" 2>/dev/null || true
}

if [[ $# -eq 1 && ("$1" == "-h" || "$1" == "--help" || "$1" == "help") ]]; then
    usage
    exit 0
fi

if [[ $# -eq 2 && "$1" == "describe" ]]; then
    profile_args "$2"
    exit 0
fi

[[ $# -ge 2 ]] || { usage >&2; exit 2; }
action="$1"
iface="$2"
shift 2
command -v tc >/dev/null 2>&1 || fail "tc from iproute2 is required"
command -v ip >/dev/null 2>&1 || fail "ip from iproute2 is required"
require_iface "$iface"

case "$action" in
    apply)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        require_root
        apply_shape "$iface" "$1"
        show_status "$iface"
        ;;
    clear)
        [[ $# -eq 0 ]] || { usage >&2; exit 2; }
        require_root
        clear_shape "$iface"
        ;;
    status)
        [[ $# -eq 0 ]] || { usage >&2; exit 2; }
        show_status "$iface"
        ;;
    interrupt)
        [[ $# -eq 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }
        require_root
        profile="$1"
        seconds="$2"
        profile_args "$profile" >/dev/null
        trap 'apply_shape "$iface" "$profile"' EXIT
        tc qdisc replace dev "$iface" root handle 1: netem loss 100%
        tc qdisc replace dev "$IFB_NAME" root handle 1: netem loss 100%
        sleep "$seconds"
        apply_shape "$iface" "$profile"
        trap - EXIT
        echo "Interruption ended; profile $profile restored."
        ;;
    run)
        [[ $# -ge 4 ]] || { usage >&2; exit 2; }
        require_root
        profile="$1"
        log_file="$2"
        shift 2
        [[ "$1" == "--" ]] || { usage >&2; exit 2; }
        shift
        [[ $# -gt 0 ]] || { usage >&2; exit 2; }
        apply_shape "$iface" "$profile"
        trap 'clear_shape "$iface"' EXIT INT TERM
        {
            echo "DinoX constrained-network profile=$profile interface=$iface"
            date --iso-8601=seconds
            show_status "$iface"
            echo "== command =="
            printf '%q ' "$@"
            echo
        } > "$log_file"
        set +e
        run_as_invoking_user "$@" >> "$log_file" 2>&1
        rc=$?
        set -e
        {
            echo "== final counters =="
            date --iso-8601=seconds
            show_status "$iface"
            echo "command_exit=$rc"
        } >> "$log_file"
        exit "$rc"
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
