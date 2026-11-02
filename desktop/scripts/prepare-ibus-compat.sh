#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# Build only the client library. Never install an IBus daemon, GTK module,
# pkg-config file, or a libibus SONAME alias in the normal library search path.
IBUS_VERSION=1.5.30
IBUS_ARCHIVE=ibus_1.5.30.orig.tar.gz
IBUS_URL=https://old-releases.ubuntu.com/ubuntu/pool/main/i/ibus/ibus_1.5.30.orig.tar.gz
IBUS_SHA256=05b84d4a45139face161596e5ade8e6c5da55cfaf6f194861da66516190f5b96
IBUS_COPYING_SHA256=5df07007198989c622f5d41de8d703e7bef3d0e79d62e24332ee739a452af62a
IBUS_LIBRARY=libibus-1.0.so.5.0.530
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
RECIPE_SHA256="$(sha256sum "$SCRIPT_PATH" | awk '{print $1}')"

fail() { echo "FAIL: $*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: scripts/prepare-ibus-compat.sh --prefix ABSOLUTE_PRIVATE_PREFIX [--source-archive FILE]
       scripts/prepare-ibus-compat.sh --check ABSOLUTE_PRIVATE_PREFIX
       scripts/prepare-ibus-compat.sh --check-library FILE
       scripts/prepare-ibus-compat.sh --self-test

Builds pinned IBus 1.5.30 into PREFIX/lib/dinox/ibus-compat with its exact
source archive and LGPL license. Uses existing development tools only;
does not install system packages or change repositories. --source-archive
uses a local copy, verified against the same source pin, without downloading.
--check validates an existing prefix without building or writing to it.
EOF
}

validate_archive() {
    python3 - "$1" <<'PY'
import pathlib
import posixpath
import sys
import tarfile

root = "ibus-1.5.30"
seen = set()
with tarfile.open(sys.argv[1], "r:gz") as source:
    for entry in source:
        path = posixpath.normpath(entry.name)
        parts = pathlib.PurePosixPath(entry.name).parts
        if entry.name.startswith("/") or ".." in parts or not (
                path == root or path.startswith(root + "/")):
            raise SystemExit("FAIL: unsafe IBus archive path: " + entry.name)
        if path in seen:
            raise SystemExit("FAIL: duplicate IBus archive path: " + entry.name)
        seen.add(path)
        # The pinned upstream release contains regular files/directories only.
        if not (entry.isfile() or entry.isdir()):
            raise SystemExit("FAIL: unsupported IBus archive entry: " + entry.name)
if root + "/configure" not in seen or root + "/COPYING" not in seen:
    raise SystemExit("FAIL: incomplete IBus source archive")
PY
}

validate_library() {
    local library="$1"
    python3 - "$library" "$(uname -m)" <<'PY'
import pathlib
import re
import struct
import subprocess
import sys

path = pathlib.Path(sys.argv[1])
machines = {"x86_64": 62, "aarch64": 183}
if path.is_symlink() or not path.is_file():
    raise SystemExit("FAIL: IBus fallback must be a regular ELF file")
with path.open("rb") as source:
    header = source.read(20)
if len(header) != 20 or header[:6] != b"\x7fELF\x02\x01":
    raise SystemExit("FAIL: IBus fallback must be a 64-bit little-endian ELF")
kind, machine = struct.unpack_from("<HH", header, 16)
if kind != 3 or machine != machines.get(sys.argv[2]):
    raise SystemExit("FAIL: IBus fallback architecture does not match this build")
dynamic = subprocess.check_output(["readelf", "-d", "--wide", str(path)], text=True)
if re.findall(r"\(SONAME\).*\[([^]]+)\]", dynamic) != ["libibus-1.0.so.5"]:
    raise SystemExit("FAIL: unexpected IBus fallback SONAME")
needed = set(re.findall(r"\(NEEDED\).*\[([^]]+)\]", dynamic))
expected = {"libgio-2.0.so.0", "libgobject-2.0.so.0", "libglib-2.0.so.0", "libc.so.6"}
if needed != expected or re.search(r"\((?:RPATH|RUNPATH)\)", dynamic):
    raise SystemExit("FAIL: unexpected IBus fallback dependencies or search path")
symbols = subprocess.check_output(["readelf", "--dyn-syms", "--wide", str(path)], text=True)
if not re.search(r"\bGLOBAL\s+DEFAULT\s+(?!UND\b)\S+\s+ibus_attr_preedit_get_type$", symbols, re.M):
    raise SystemExit("FAIL: IBus 1.5.30 public symbol is missing")
PY
}

metadata() {
    printf 'component=ibus-compat\nversion=%s\nsource_url=%s\narchive=%s\nchecksum_algorithm=sha256\nchecksum=%s\nlicense_expression=LGPL-2.1-or-later\n' \
        "$IBUS_VERSION" "$IBUS_URL" "$IBUS_ARCHIVE" "$IBUS_SHA256"
}

check_prefix() {
    local prefix="$1"
    local root="$prefix/lib/dinox/ibus-compat"
    local licenses="$prefix/share/dinox/custom-dependency-licenses/ibus-compat"
    local sources="$prefix/share/dinox/corresponding-sources/ibus-compat"
    local file
    for file in "$root/$IBUS_LIBRARY" "$root/METADATA" "$licenses/METADATA" \
            "$licenses/files/COPYING" "$sources/METADATA" "$sources/$IBUS_ARCHIVE"; do
        [[ -f "$file" && ! -L "$file" ]] || return 1
        [[ "$(readlink -f -- "$file")" == "$prefix/"* ]] || return 1
    done
    validate_library "$root/$IBUS_LIBRARY" || return 1
    cmp -s <(metadata) "$sources/METADATA" || return 1
    cmp -s <(metadata) "$licenses/METADATA" || return 1
    cmp -s <(metadata; printf 'recipe_sha256=%s\narchitecture=%s\nlibrary_sha256=%s\n' \
        "$RECIPE_SHA256" "$(uname -m)" "$(sha256sum "$root/$IBUS_LIBRARY" | awk '{print $1}')") \
        "$root/METADATA" || return 1
    printf '%s  %s\n' "$IBUS_SHA256" "$sources/$IBUS_ARCHIVE" \
        | sha256sum --check --status || return 1
    printf '%s  %s\n' "$IBUS_COPYING_SHA256" "$licenses/files/COPYING" \
        | sha256sum --check --status || return 1
    # No alias may accidentally override the default resolver for modern IBus.
    [[ ! -e "$root/libibus-1.0.so.5" && ! -L "$root/libibus-1.0.so.5" ]] || return 1
}

safe_prefix() {
    [[ "$1" == /* ]] || { echo "FAIL: IBus prefix must be absolute" >&2; return 1; }
    local prefix="$(realpath -m -- "$1")"
    case "$prefix" in /|/usr|/usr/local|/lib|/lib64|/opt|/etc|/bin|/sbin)
        echo "FAIL: IBus prefix must be a private dependency prefix" >&2; return 1 ;; esac
    printf '%s\n' "$prefix"
}

run_self_test() (
    local work
    work="$(mktemp -d)"
    trap 'rm -rf -- "$work"' EXIT
    if safe_prefix /usr >/dev/null 2>&1 || safe_prefix relative >/dev/null 2>&1; then
        fail "unsafe prefix accepted"
    fi
    python3 - "$work/escape.tar.gz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as archive:
    entry = tarfile.TarInfo("ibus-1.5.30/../escape")
    entry.size = 1
    archive.addfile(entry, io.BytesIO(b"x"))
PY
    if validate_archive "$work/escape.tar.gz" >/dev/null 2>&1; then
        fail "archive traversal accepted"
    fi
    printf 'void ibus_attr_preedit_get_type(void) {}\n' > "$work/library.c"
    cc -shared -fPIC "$work/library.c" -Wl,-soname,libibus-1.0.so.5 \
        -Wl,--no-as-needed $(pkg-config --libs gio-2.0 gobject-2.0 glib-2.0) \
        -o "$work/$IBUS_LIBRARY"
    validate_library "$work/$IBUS_LIBRARY"
    cp "$work/$IBUS_LIBRARY" "$work/wrong-architecture.so"
    python3 - "$work/wrong-architecture.so" <<'PY'
import sys
with open(sys.argv[1], "r+b") as library:
    library.seek(18)
    library.write(b"\x00\x00")
PY
    if validate_library "$work/wrong-architecture.so" >/dev/null 2>&1; then
        fail "wrong architecture accepted"
    fi
    ln -s "$work/$IBUS_LIBRARY" "$work/alias.so"
    if validate_library "$work/alias.so" >/dev/null 2>&1; then
        fail "symlink payload accepted"
    fi
    if check_prefix "$work" >/dev/null 2>&1; then
        fail "markerless IBus cache accepted"
    fi
    echo "OK: IBus prefix, archive traversal, ELF architecture, symlink and cache checks"
)

PREFIX=""
SOURCE_ARCHIVE=""
CHECK_ONLY=false
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --prefix|--check)
            [[ "$#" -ge 2 && -z "$PREFIX" ]] || fail "one prefix is required"
            [[ "$1" != --check ]] || CHECK_ONLY=true
            PREFIX="$(safe_prefix "$2")"; shift 2 ;;
        --source-archive)
            [[ "$#" -ge 2 ]] || fail "missing source archive"
            SOURCE_ARCHIVE="$(readlink -f -- "$2")"; shift 2 ;;
        --check-library)
            [[ "$#" -eq 2 ]] || fail "--check-library requires one file"
            validate_library "$2"
            echo "OK: private IBus ELF validated"
            exit 0 ;;
        --self-test)
            [[ "$#" -eq 1 ]] || fail "--self-test takes no other arguments"
            run_self_test; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done
[[ -n "$PREFIX" ]] || { usage >&2; exit 2; }
[[ "$(uname -s)" == Linux ]] || fail "IBus compatibility helper is Linux-only"
case "$(uname -m)" in x86_64|aarch64) ;; *) fail "unsupported IBus build architecture" ;; esac
if $CHECK_ONLY; then
    check_prefix "$PREFIX" || fail "IBus compatibility prefix is incomplete or stale: $PREFIX"
    echo "OK: private IBus $IBUS_VERSION validated"
    exit 0
fi
for tool in cc curl make pkg-config python3 readelf sha256sum strip tar; do
    command -v "$tool" >/dev/null || fail "$tool is required; use the existing BUILD.md toolchain"
done
pkg-config --exists glib-2.0 gobject-2.0 gio-2.0 gio-unix-2.0 iso-codes \
    || fail "IBus client build needs the existing GLib and iso-codes development files"
install -d -m 0755 "$PREFIX"
LOCK="$PREFIX/.dinox-ibus-compat.lock"
mkdir -- "$LOCK" 2>/dev/null || fail "another IBus preparation is active, or a stale lock exists: $LOCK"
WORK=""
trap 'status=$?; set +e; [[ -z "$WORK" ]] || rm -rf -- "$WORK"; rmdir -- "$LOCK"; exit "$status"' EXIT
if check_prefix "$PREFIX" >/dev/null 2>&1; then
    echo "OK: using validated private IBus $IBUS_VERSION"
    exit 0
fi
# Reject any destination ancestry that escapes the prefix via a symlink.
for relative in lib/dinox/ibus-compat share/dinox/custom-dependency-licenses/ibus-compat \
        share/dinox/corresponding-sources/ibus-compat; do
    [[ "$(realpath -m -- "$PREFIX/$relative")" == "$PREFIX/"* ]] \
        || fail "IBus destination escapes its private prefix: $relative"
done
WORK="$(mktemp -d "$PREFIX/.build-ibus-compat.XXXXXX")"
ARCHIVE_PATH="$WORK/$IBUS_ARCHIVE"
if [[ -n "$SOURCE_ARCHIVE" ]]; then
    cp -- "$SOURCE_ARCHIVE" "$ARCHIVE_PATH"
else
    curl --proto '=https' --tlsv1.2 --fail --location --show-error --retry 3 \
        --connect-timeout 20 --max-time 300 --output "$ARCHIVE_PATH" "$IBUS_URL"
fi
printf '%s  %s\n' "$IBUS_SHA256" "$ARCHIVE_PATH" | sha256sum --check --status \
    || fail "IBus source checksum mismatch"
validate_archive "$ARCHIVE_PATH"
tar --no-same-owner -xzf "$ARCHIVE_PATH" -C "$WORK"
(
    cd "$WORK/ibus-$IBUS_VERSION"
    # Upstream configure also checks libdbus for daemon/tests that this recipe
    # never builds. Its supported flag overrides skip that unused check;
    # src/libibus-1.0.la uses GLib/GObject/GIO and their GDBus API exclusively.
    # IBus 1.5.30 relies on pre-C23 empty parameter-list semantics. GCC 15
    # defaults to C23; retain the tested GNU C17 mode for this dependency only,
    # preserving the caller's optimization and hardening flags.
    CFLAGS="${CFLAGS:--g -O2} -std=gnu17" \
    DBUS_CFLAGS=' ' DBUS_LIBS=' ' \
        ./configure --prefix="$PREFIX" --libdir="$PREFIX/lib/dinox/ibus-compat" \
        --disable-gtk2 --disable-gtk3 --disable-gtk4 --disable-xim --disable-wayland \
        --disable-ui --disable-appindicator --disable-engine --disable-dconf \
        --disable-libnotify --disable-setup --disable-python2 --disable-python-library \
        --disable-dbus-python-check --disable-introspection --disable-vala \
        --disable-gtk-doc --disable-tests --disable-install-tests --disable-emoji-dict \
        --disable-unicode-dict --disable-systemd-services --disable-schemas-compile \
        --disable-static --disable-maintainer-mode
    make -C src -j1 libibus-1.0.la
)
BUILT_LIBRARY="$WORK/ibus-$IBUS_VERSION/src/.libs/$IBUS_LIBRARY"
strip --strip-unneeded "$BUILT_LIBRARY"
validate_library "$BUILT_LIBRARY"
STAGED_LIBRARY_ROOT="$WORK/installed"
install -d -m 0755 "$STAGED_LIBRARY_ROOT"
install -m 0644 "$BUILT_LIBRARY" "$STAGED_LIBRARY_ROOT/$IBUS_LIBRARY"
{ metadata; printf 'recipe_sha256=%s\narchitecture=%s\nlibrary_sha256=%s\n' \
    "$RECIPE_SHA256" "$(uname -m)" "$(sha256sum "$BUILT_LIBRARY" | awk '{print $1}')"; } \
    > "$STAGED_LIBRARY_ROOT/METADATA"
LICENSE_ROOT="$PREFIX/share/dinox/custom-dependency-licenses/ibus-compat"
SOURCE_ROOT="$PREFIX/share/dinox/corresponding-sources/ibus-compat"
install -d -m 0755 "$LICENSE_ROOT/files" "$SOURCE_ROOT" "$PREFIX/lib/dinox"
install -m 0644 "$WORK/ibus-$IBUS_VERSION/COPYING" "$LICENSE_ROOT/files/COPYING"
metadata > "$LICENSE_ROOT/METADATA"
metadata > "$SOURCE_ROOT/METADATA"
install -m 0644 "$ARCHIVE_PATH" "$SOURCE_ROOT/$IBUS_ARCHIVE"
rm -rf -- "$PREFIX/lib/dinox/ibus-compat"
mv -- "$STAGED_LIBRARY_ROOT" "$PREFIX/lib/dinox/ibus-compat"
check_prefix "$PREFIX" || fail "prepared IBus compatibility prefix failed validation"
echo "OK: private IBus $IBUS_VERSION ready at $PREFIX/lib/dinox/ibus-compat/$IBUS_LIBRARY"
