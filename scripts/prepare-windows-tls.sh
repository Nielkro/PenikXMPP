#!/usr/bin/env bash
# Private GIO TLS module: load UTF-8 CA filenames via GLib on Windows.
set -euo pipefail
export PYTHONUTF8=1
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_ROOT="${DINOX_WINDOWS_VENDOR_ROOT:-$(dirname "$PROJECT_ROOT")/vendor-deps}"
VERSION=2.80.1
SOURCE_SHA256=b80e2874157cd55071f1b6710fa0b911d5ac5de106a9ee2a4c9c7bee61782f8e
SOURCE_URL="https://download.gnome.org/sources/glib-networking/2.80/glib-networking-$VERSION.tar.xz"
PATCH="$PROJECT_ROOT/scripts/patches/glib-networking-windows-utf8-ca.patch"
ROOT="$VENDOR_ROOT/glib-networking-$VERSION-dinox"
MATERIAL="$VENDOR_ROOT/windows-license-material/glib-networking-$VERSION-dinox"
JOBS="${DINOX_BUILD_JOBS:-${DINOX_CI_JOBS:-2}}"
CHECK_ONLY=false
case "${1:-}" in
    --check) CHECK_ONLY=true ;;
    "") ;;
    *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac
[[ "$#" -le 1 ]] || exit 2
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid build job limit' >&2; exit 2; }
case "$(uname -s)" in MINGW*|MSYS*) ;; *) echo 'Run in MSYS2 MINGW64' >&2; exit 2;; esac
[[ "${MSYSTEM:-}" == MINGW64 ]] || { echo 'MINGW64 is required' >&2; exit 2; }
for tool in curl sha256sum tar patch meson ninja pkg-config; do command -v "$tool" >/dev/null; done
PATCH_SHA256="$(sha256sum "$PATCH" | cut -d' ' -f1)"
STAMP="$SOURCE_SHA256:$PATCH_SHA256:$(sha256sum "$0" | cut -d' ' -f1):$(pkg-config --modversion gio-2.0 gnutls | tr '\n' ':')"
if [[ -s "$ROOT/lib/gio/modules/libgiognutls.dll" && -f "$ROOT/BUILD-ID" && -s "$ROOT/SHA256SUMS" && -f "$MATERIAL/METADATA" ]] &&
        [[ "$(cat "$ROOT/BUILD-ID")" == "$STAMP" ]] &&
        (cd "$ROOT" && sha256sum -c --status SHA256SUMS) &&
        cmp -s "$PATCH" "$MATERIAL/files/glib-networking-windows-utf8-ca.patch"; then
    echo "Private Windows TLS module is current: $ROOT"
    exit 0
fi
$CHECK_ONLY && { echo "Private Windows TLS module missing or stale; run scripts/prepare-windows-tls.sh" >&2; exit 1; }
mkdir -p "$VENDOR_ROOT/downloads" "$ROOT" "$MATERIAL/files"
ARCHIVE="$VENDOR_ROOT/downloads/glib-networking-$VERSION.tar.xz"
if ! { [[ -f "$ARCHIVE" ]] && printf '%s  %s\n' "$SOURCE_SHA256" "$ARCHIVE" | sha256sum -c --status; }; then
    curl --fail --location --retry 3 --connect-timeout 15 --max-time 120 "$SOURCE_URL" -o "$ARCHIVE.part"
    printf '%s  %s\n' "$SOURCE_SHA256" "$ARCHIVE.part" | sha256sum -c -
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
WORK="$(mktemp -d "$ROOT/build.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
# Archive is pinned before extraction; cleanup touches only this owned workdir.
tar -xf "$ARCHIVE" -C "$WORK"
SOURCE="$WORK/glib-networking-$VERSION"
patch --batch --fuzz=0 -d "$SOURCE" -p1 < "$PATCH"
python3 "$PROJECT_ROOT/scripts/windows-compiler-paths.py" \
    --write-native-file "$(cygpath -m "$WORK/compiler.ini")"
meson setup "$WORK/build" "$SOURCE" --native-file "$WORK/compiler.ini" --buildtype=release \
    -Dlibproxy=disabled -Dgnome_proxy=disabled -Denvironment_proxy=disabled \
    -Dgnutls=enabled -Dopenssl=disabled -Dinstalled_tests=false
meson compile -C "$WORK/build" -j "$JOBS" giognutls
mkdir -p "$ROOT/lib/gio/modules"
cp "$WORK/build/tls/gnutls/libgiognutls.dll" "$ROOT/lib/gio/modules/"
cp "$SOURCE/COPYING" "$MATERIAL/files/"
cp "$PATCH" "$MATERIAL/files/"
cp "$0" "$MATERIAL/files/prepare-windows-tls.sh"
cp "$PROJECT_ROOT/scripts/windows-compiler-paths.py" "$MATERIAL/files/"
cat > "$MATERIAL/METADATA" <<META
component=glib-networking-dinox
version=$VERSION
license_expression=LGPL-2.1-or-later
source_url=$SOURCE_URL
checksum_algorithm=sha256
checksum=$SOURCE_SHA256
patch_sha256=$PATCH_SHA256
META
printf '%s\n' "$STAMP" > "$ROOT/BUILD-ID"
(cd "$ROOT" && sha256sum lib/gio/modules/libgiognutls.dll > SHA256SUMS)
echo "Private Windows TLS module prepared: $ROOT"
