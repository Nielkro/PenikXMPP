#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
RUNINFO_FILE="$LOG_DIR/dinox-runinfo-latest.txt"

usage() {
  cat <<'USAGE'
Usage: scripts/scan-dinox-latest-log.sh

Scans the latest DinoX debug log recorded by scripts/run-dinox-debug.sh and
prints high-signal warning/error sections.
USAGE
}

if [[ $# -gt 1 ]]; then
  echo "Unknown arguments: $*" >&2
  usage >&2
  exit 2
elif [[ "${1-}" == "--help" || "${1-}" == "-h" ]]; then
  usage
  exit 0
elif [[ -n "${1-}" ]]; then
  echo "Unknown argument: $1" >&2
  usage >&2
  exit 2
fi

if [[ ! -f "$RUNINFO_FILE" ]]; then
  echo "No $RUNINFO_FILE found." >&2
  exit 1
fi

log_file="$(cat "$RUNINFO_FILE")"
if [[ -z "$log_file" || ! -f "$log_file" ]]; then
  echo "Log file not found: $log_file" >&2
  exit 1
fi

echo "LOG=$log_file"
echo

section() {
  local title="$1"
  local pattern="$2"
  local limit="$3"

  echo "== $title =="
  grep -nEi -- "$pattern" "$log_file" | head -n "$limit" || true
  echo
}

section "High-signal warnings/errors" \
  "warn|warning|error|critical|fatal|assertion.*failed" 200
section "Crash / freeze indicators" \
  "segmentation fault|speicherzugriffsfehler|sig(segv|abrt|trap)|core dump|deadlock|watchdog|freeze|frozen|not responding" 100
section "GTK / GDK / AT-SPI / GObject" \
  "gtk-(warning|critical)|gdk-(warning|critical)|glib-gobject-(warning|critical)|gtk_at_context_set_accessible_role|accessible.*role|accessibility bus|at-spi|org\\.a11y\\.Bus|gdk_surface_get_device_position|gtk_widget_is_ancestor|_gtk_widget_find_at_coords|has no handler with id" 150
section "SASL / authentication" \
  "sasl:|scram:|channel\\.bind|downgrade|not-authorized|authentication.*fail" 80
section "Certificate / TLS" \
  "certificate.*pinned|fingerprint.*changed|unknown ca|gdummytls|gio-tls-backend|tls support is not available|gio_extra_modules|giognutls" 80
section "XMPP transport / IQ timeouts" \
  "timed out waiting for iq response|failed to send ping|stream.*(error|closed)|connection.*(lost|fail)|reconnect" 100
section "OMEMO" \
  "omemo.*(fail|error|warning)|decrypt.*fail|bundle.*fail|session.*error|device.*list.*fail" 100
section "OpenPGP / GPG helpers" \
  "xep-0373|openpgp.*(fail|error|warning)|gpg:|gpgconf|gpg-agent|dirmngr|keyserver.*(fail|timeout)|ipc connect call failed" 100
section "MQTT / bridges" \
  "mqtt|bridge.*(deliver|match|drop|fail|error)|mosquitto|topic.*(publish|subscribe)" 160
section "Google/libwebrtc calls and worker" \
  "google-webrtc|libwebrtc|dinox-webrtc-worker|jingle.*(call|session)|jmi|peerconnection|dtmf|rtp.*(bytes|packets)|rtt|jitter|call.*(fail|error)" 200
section "Recorder / decoder / playback" \
  "webrtc-recorder|vp8.*decoder|ffmpeg|media foundation|gstreamer|gst-|underflow|skipping segment|audioringbuffer|too late|discont" 200
section "File transfer / ICE / SOCKS5" \
  "file_send_data.*null|prepare_send_file|upload.*fail|filesenderror|jingle.*file|socks5|s5b|libnice|turn refresh|ice.*(fail|error)" 160
section "MUC / bookmarks / UI timing" \
  "muc|groupchat|bookmark|conversation|active|restore|presence|affiliation|role|mam|join|leave|conference|ui-timing|muc-avatar|occupant-shadow" 200
section "Botmother" \
  "botmother:|botomemo:|botrouter:|sessionpool:.*(rejected|ignored)|telegram:.*(fail|error)" 100
section "Tor" \
  "\\[tor\\]|torcontroller|obfs4|lyrebird|bridge.*fail" 80
