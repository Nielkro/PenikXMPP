#!/usr/bin/env bash
set -euo pipefail

# Keep Ubuntu's fixes, but make its in-process sound modules relocatable.
# This private build is used only by the AppImage, never installed on the host.
VERSION=0.30-10ubuntu10
SOURCE_BASE=https://archive.ubuntu.com/ubuntu/pool/main/libc/libcanberra
RECIPE="$(readlink -f -- "${BASH_SOURCE[0]}")"
RECIPE_SHA="$(sha256sum "$RECIPE" | awk '{print $1}')"
FILES=(libcanberra_0.30.orig.tar.xz libcanberra_0.30-10ubuntu10.debian.tar.xz libcanberra_0.30-10ubuntu10.dsc)
HASHES=(c2b671e67e0c288a69fc33dc1b6f1b534d07882c2aceed37004bf48c601afa72 8d1e21b8a548fbcec6014a2558aa935ddd59befac8dd4989a18a9e34fee2c8c8 1eb48fd0e8c83a61fed041497e892d4987048737476ba2b16dac03d3c0a7b5d0)
MODULES=(alsa pulse multi null)
PREFIX=""
SOURCE_DIR=""
CHECK=false
WORK=""

fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() { [ -z "$WORK" ] || rm -rf -- "$WORK"; }
trap cleanup EXIT

metadata() {
    printf 'component=canberra-runtime\nversion=%s\nsource_url=%s\nlicense_expression=LGPL-2.1-or-later\nrecipe_sha256=%s\narchitecture=%s\n' \
        "$VERSION" "$SOURCE_BASE" "$RECIPE_SHA" "$(uname -m)"
}

check_prefix() (
    local runtime="$PREFIX/lib/dinox/canberra-runtime"
    local sources="$PREFIX/share/dinox/corresponding-sources/canberra-runtime"
    local licenses="$PREFIX/share/dinox/custom-dependency-licenses/canberra-runtime"
    local i module
    [ -f "$runtime/METADATA" ] && cmp -s <(metadata) "$runtime/METADATA" || return 1
    [ -s "$runtime/SHA256SUMS" ] && [ -s "$licenses/files/COPYING" ] || return 1
    cmp -s "$runtime/METADATA" "$sources/METADATA" || return 1
    cmp -s "$runtime/METADATA" "$licenses/METADATA" || return 1
    printf '%s  %s\n' "$RECIPE_SHA" "$sources/prepare-canberra-runtime.sh" | sha256sum --check --status || return 1
    [ -f "$runtime/libcanberra.so.0" ] && [ ! -L "$runtime/libcanberra.so.0" ] || return 1
    readelf -d "$runtime/libcanberra.so.0" | grep -F 'Library soname: [libcanberra.so.0]' >/dev/null || return 1
    grep -aqF 'DINOX_CANBERRA_MODULE_DIR' "$runtime/libcanberra.so.0" || return 1
    for module in "${MODULES[@]}"; do
        [ -s "$runtime/modules/libcanberra-$module.so" ] || return 1
    done
    (cd "$runtime" && sha256sum --check --status SHA256SUMS) || return 1
    for i in "${!FILES[@]}"; do
        printf '%s  %s\n' "${HASHES[$i]}" "$sources/${FILES[$i]}" | sha256sum --check --status || return 1
    done
)

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix|--check)
            [ "$#" -ge 2 ] && [ -z "$PREFIX" ] || fail "one private prefix is required"
            [ "$1" != --check ] || CHECK=true
            [[ "$2" == /* ]] || fail "prefix must be absolute"
            PREFIX="$(realpath -m -- "$2")"
            case "$PREFIX" in /|/usr|/usr/local|/lib|/lib64|/opt|/etc|/bin|/sbin) fail "prefix must be private" ;; esac
            shift 2 ;;
        --source-dir)
            [ "$#" -ge 2 ] || fail "source directory is required"
            SOURCE_DIR="$(realpath -- "$2")"; shift 2 ;;
        -h|--help)
            echo 'Usage: prepare-canberra-runtime.sh --prefix PRIVATE_PREFIX [--source-dir VERIFIED_SOURCE_DIRECTORY]'
            echo '       prepare-canberra-runtime.sh --check PRIVATE_PREFIX'
            exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done
[ -n "$PREFIX" ] || fail "--prefix or --check is required"
if $CHECK; then
    check_prefix || fail "private libcanberra runtime is incomplete or stale"
    echo "OK: private libcanberra runtime validated"
    exit 0
fi
for tool in cc curl make pkg-config python3 readelf sha256sum dpkg-source patchelf flock; do
    command -v "$tool" >/dev/null || fail "$tool is required"
done
pkg-config --exists libpulse alsa vorbisfile tdb || fail "libpulse, ALSA, Vorbis and TDB development files are required"
mkdir -p "$PREFIX"
exec 9>"$PREFIX/.canberra-runtime.lock"
flock 9
if check_prefix >/dev/null 2>&1; then
    echo "OK: reusing verified libcanberra runtime"
    exit 0
fi
WORK="$(mktemp -d "$PREFIX/.build-canberra.XXXXXX")"
for i in "${!FILES[@]}"; do
    if [ -n "$SOURCE_DIR" ]; then
        cp -- "$SOURCE_DIR/${FILES[$i]}" "$WORK/${FILES[$i]}"
    else
        curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 20 --max-time 180 \
            "$SOURCE_BASE/${FILES[$i]}" -o "$WORK/${FILES[$i]}"
    fi
    printf '%s  %s\n' "${HASHES[$i]}" "$WORK/${FILES[$i]}" | sha256sum --check --status \
        || fail "libcanberra source checksum mismatch"
done
dpkg-source --no-check -x "$WORK/libcanberra_$VERSION.dsc" "$WORK/source"
python3 - "$WORK/source/src/dso.c" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '''        char *mn;
        struct private_dso *p;

        p = PRIVATE_DSO(c);

        if (!(mn = ca_sprintf_malloc(CA_PLUGIN_PATH "/libcanberra-%s", t)))'''
new = '''        char *mn;
        struct private_dso *p;
        const char *module_dir;

        p = PRIVATE_DSO(c);
        module_dir = getenv("DINOX_CANBERRA_MODULE_DIR");
        if (!module_dir || !module_dir[0])
                module_dir = CA_PLUGIN_PATH;

        if (!(mn = ca_sprintf_malloc("%s/libcanberra-%s", module_dir, t)))'''
if s.count(old) != 1:
    raise SystemExit("FAIL: libcanberra module loader does not match the pinned source")
p.write_text(s.replace(old, new))
PY
(
    cd "$WORK/source"
    CFLAGS="${CFLAGS:--O2 -g} -std=gnu17 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3" ./configure --prefix=/usr --libdir=/usr/lib/dinox \
        --disable-gtk --disable-gtk3 --disable-gstreamer --disable-oss \
        --enable-alsa --enable-pulse --enable-null --enable-multi --enable-tdb \
        --disable-static --disable-gtk-doc --with-builtin=dso
    # Upstream's 2012 warning flags force FORTIFY=2. Retain the Ubuntu 24.04
    # toolchain's stronger level 3 without defining the macro twice.
    canberra_warning_flags="$(sed -n 's/^WARNINGFLAGS = //p' src/Makefile)"
    canberra_warning_flags="${canberra_warning_flags//-Wp,-D_FORTIFY_SOURCE=2/}"
    make -C src -j1 WARNINGFLAGS="$canberra_warning_flags" \
        libcanberra.la libcanberra-alsa.la libcanberra-pulse.la libcanberra-multi.la libcanberra-null.la
)
runtime="$WORK/installed"
mkdir -p "$runtime/modules"
install -m 0644 "$WORK/source/src/.libs/libcanberra.so.0.2.5" "$runtime/libcanberra.so.0"
patchelf --set-rpath '$ORIGIN:$ORIGIN/..' "$runtime/libcanberra.so.0"
for module in "${MODULES[@]}"; do
    install -m 0644 "$WORK/source/src/.libs/libcanberra-$module.so" "$runtime/modules/"
    patchelf --set-rpath '$ORIGIN/..:$ORIGIN/../..' "$runtime/modules/libcanberra-$module.so"
done
metadata > "$runtime/METADATA"
(cd "$runtime" && sha256sum libcanberra.so.0 modules/*.so > SHA256SUMS)
sources="$PREFIX/share/dinox/corresponding-sources/canberra-runtime"
licenses="$PREFIX/share/dinox/custom-dependency-licenses/canberra-runtime"
mkdir -p "$sources" "$licenses/files" "$PREFIX/lib/dinox"
for file in "${FILES[@]}"; do install -m 0644 "$WORK/$file" "$sources/$file"; done
install -m 0644 "$RECIPE" "$sources/prepare-canberra-runtime.sh"
install -m 0644 "$WORK/source/LGPL" "$licenses/files/COPYING"
install -m 0644 "$WORK/source/debian/copyright" "$licenses/files/debian-copyright"
metadata > "$sources/METADATA"
metadata > "$licenses/METADATA"
rm -rf -- "$PREFIX/lib/dinox/canberra-runtime"
mv "$runtime" "$PREFIX/lib/dinox/canberra-runtime"
check_prefix || fail "prepared libcanberra runtime failed validation"
echo "OK: private libcanberra runtime ready at $PREFIX/lib/dinox/canberra-runtime"
