#!/usr/bin/env bash
set -euo pipefail

APPIMAGE_PATH="${1:-/opt/DinoX.AppImage}"
EXPECTED_VERSION="${DINOX_EXPECTED_VERSION:-}"
EXTRACT_ROOT=""
GNUPG_HOME=""
APPDIR=""

fail() {
    echo "AppImage runtime gate failed: $*" >&2
    exit 1
}

run_gnupg() {
    timeout --kill-after=2s 10s \
        env -u GPG_AGENT_INFO \
        APPDIR="$APPDIR" \
        APPIMAGE="$APPIMAGE_PATH" \
        HOME="$(dirname "$GNUPG_HOME")" \
        GNUPGHOME="$GNUPG_HOME" \
        PATH="$APPDIR/usr/bin:/usr/bin:/bin" \
        LD_LIBRARY_PATH="$APPDIR/usr/lib/dinox:$APPDIR/usr/lib:$APPDIR/usr/lib/x86_64-linux-gnu" \
        LC_ALL=C \
        "$@"
}

cleanup() {
    if [ -n "$APPDIR" ] && [ -n "$GNUPG_HOME" ] \
            && [ -x "$APPDIR/usr/bin/gpgconf" ]; then
        run_gnupg "$APPDIR/usr/bin/gpgconf" --homedir "$GNUPG_HOME" \
            --kill all >/dev/null 2>&1 || true
    fi
    [ -z "$EXTRACT_ROOT" ] || rm -rf "$EXTRACT_ROOT"
}
trap cleanup EXIT

[ -n "$EXPECTED_VERSION" ] \
    || fail "DINOX_EXPECTED_VERSION is required"
[ -s "$APPIMAGE_PATH" ] \
    || fail "AppImage is missing: $APPIMAGE_PATH"
[ -x "$APPIMAGE_PATH" ] \
    || fail "AppImage is not executable: $APPIMAGE_PATH"

for directory in \
    "${HOME:-/tmp/dinox-home}" \
    "${TMPDIR:-/tmp/dinox-tmp}" \
    "${XDG_RUNTIME_DIR:-/tmp/dinox-runtime}"; do
    mkdir -p "$directory"
    chmod 0700 "$directory"
done

version_output="$(
    timeout --kill-after=5s 60s \
        env APPIMAGE_EXTRACT_AND_RUN=1 \
        GSETTINGS_BACKEND=memory \
        HOME="${HOME:-/tmp/dinox-home}" \
        NO_AT_BRIDGE=1 \
        TMPDIR="${TMPDIR:-/tmp/dinox-tmp}" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/dinox-runtime}" \
        "$APPIMAGE_PATH" --version 2>&1
)" || fail "DinoX --version failed: $version_output"
printf '%s\n' "$version_output"
grep -Fxq "DinoX $EXPECTED_VERSION" <<<"$version_output" \
    || fail "unexpected version output (expected DinoX $EXPECTED_VERSION)"

EXTRACT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dinox-appimage-runtime-gate.XXXXXX")"
(
    cd "$EXTRACT_ROOT"
    timeout --kill-after=5s 120s \
        "$APPIMAGE_PATH" --appimage-extract >/dev/null
)
APPDIR="$EXTRACT_ROOT/squashfs-root"
[ -x "$APPDIR/usr/bin/gpgconf" ] \
    || fail "extracted AppImage has no executable gpgconf"

GNUPG_HOME="$EXTRACT_ROOT/gnupg"
mkdir -m 0700 "$GNUPG_HOME"

for helper in gpg gpgconf gpg-agent dirmngr gpg-connect-agent; do
    output="$(run_gnupg "$APPDIR/usr/bin/$helper" --version 2>&1)" \
        || fail "$helper --version failed"
    version="$(
        sed -nE '1s/^.*\(GnuPG\) ([0-9]+(\.[0-9]+)+).*$/\1/p' \
            <<<"$output"
    )"
    case "$version" in
        2.4.*) ;;
        *) fail "$helper reports unsupported GnuPG version: ${version:-unknown}" ;;
    esac
done

dirs="$(
    run_gnupg "$APPDIR/usr/bin/gpgconf" --homedir "$GNUPG_HOME" \
        --list-dirs 2>/dev/null
)"
grep -Fxq "bindir:$APPDIR/usr/bin" <<<"$dirs" \
    || fail "gpgconf bindir is not relocatable"
grep -Fxq "sysconfdir:$APPDIR/usr/etc/gnupg" <<<"$dirs" \
    || fail "gpgconf sysconfdir is not relocatable"
grep -Fxq "datadir:$APPDIR/usr/share/gnupg" <<<"$dirs" \
    || fail "gpgconf datadir is not relocatable"
grep -Fxq "homedir:$GNUPG_HOME" <<<"$dirs" \
    || fail "gpgconf homedir escaped the isolated gate"

components="$(
    run_gnupg "$APPDIR/usr/bin/gpgconf" --homedir "$GNUPG_HOME" \
        --list-components 2>/dev/null
)"
grep -Fxq "gpg:OpenPGP:$APPDIR/usr/bin/gpg" <<<"$components" \
    || fail "gpgconf does not resolve the bundled gpg"
grep -Fxq "gpg-agent:Private Keys:$APPDIR/usr/bin/gpg-agent" <<<"$components" \
    || fail "gpgconf does not resolve the bundled gpg-agent"
grep -Fxq "dirmngr:Network:$APPDIR/usr/bin/dirmngr" <<<"$components" \
    || fail "gpgconf does not resolve the bundled dirmngr"

run_gnupg "$APPDIR/usr/bin/gpgconf" --homedir "$GNUPG_HOME" \
    --launch gpg-agent >/dev/null 2>&1 \
    || fail "gpg-agent launch failed"
run_gnupg "$APPDIR/usr/bin/gpgconf" --homedir "$GNUPG_HOME" \
    --launch dirmngr >/dev/null 2>&1 \
    || fail "dirmngr launch failed"
run_gnupg "$APPDIR/usr/bin/gpgconf" --homedir "$GNUPG_HOME" \
    --kill all >/dev/null 2>&1 \
    || fail "GnuPG helper shutdown failed"

echo "AppImage runtime gate passed: offline startup and bundled GnuPG helper lifecycle."
