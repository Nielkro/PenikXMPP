#!/bin/bash
set -euo pipefail

# ============================================================================
# Custom dependency builder for CI
#
# Usage:
#   ./scripts/ci-build-deps.sh           Build & install all dependencies
#   ./scripts/ci-build-deps.sh --clean   Remove previously installed dependencies
#
# TODO: Check periodically for newer versions!
# Current versions (last checked/verified: 2026-05-14):
#   SQLCipher              4.6.1   https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/
#   libnice                0.1.23  https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/
#   protobuf-c             1.5.2   https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/
#   libomemo-c             0.5.1   https://git.dinox.im/dinoxim/libomemo-c/releases/download/v0.5.1/
#   cJSON                  1.7.19  https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/
#   mosquitto              2.1.2   https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/
#   tor                    0.4.9.12 https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/
#   lyrebird               0.8.1   https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/
#   recorder FFmpeg        8.1.2   https://ffmpeg.org/releases/
#   recorder x264          b35605ace3ddf7c1a5d67a2eb553f034aef41d55
#                                https://code.videolan.org/videolan/x264/
#
# When updating versions: bump the *_VER variables below. The CI cache
# key is derived from this file's hash, so any edit auto-invalidates caches.
#
# Requirements: golang-go >= 1.22 must be installed for lyrebird build.
# ============================================================================

CUSTOM_PREFIX="${DINOX_CUSTOM_DEPENDENCY_PREFIX:-/opt/dinox-deps}"
CUSTOM_PREFIX="$(realpath -m -- "$CUSTOM_PREFIX")"
CUSTOM_BINDIR="$CUSTOM_PREFIX/bin"
CUSTOM_LIBDIR="$CUSTOM_PREFIX/lib"
CUSTOM_LICENSE_ROOT="${DINOX_CUSTOM_DEPENDENCY_LICENSE_ROOT:-$CUSTOM_PREFIX/share/dinox/custom-dependency-licenses}"
CUSTOM_LICENSE_ROOT="$(realpath -m -- "$CUSTOM_LICENSE_ROOT")"
CUSTOM_SOURCE_ROOT="${DINOX_CUSTOM_DEPENDENCY_SOURCE_ROOT:-$CUSTOM_PREFIX/share/dinox/corresponding-sources}"
CUSTOM_SOURCE_ROOT="$(realpath -m -- "$CUSTOM_SOURCE_ROOT")"
RECORDER_FFMPEG_ROOT="${DINOX_RECORDER_FFMPEG_ROOT:-$CUSTOM_PREFIX/libexec/dinox-recorder-ffmpeg}"
RECORDER_FFMPEG_ROOT="$(realpath -m -- "$RECORDER_FFMPEG_ROOT")"
LIBOMEMO_C_README_SHA256="83adeac2f4760208e75160502dce8931a9c918151fb4518ce6e3f011abed2057"
LIBOMEMO_C_ADDITIONAL_PERMISSION='Additional Permissions For Submission to Apple App Store: Provided that you are otherwise in compliance with the GPLv3 for each covered work you convey (including without limitation making the Corresponding Source available in compliance with Section 6 of the GPLv3), Open Whisper Systems and Dino Team also grant you the additional permission to convey through the Apple App Store non-source executable versions of the Program as incorporated into each applicable covered work as Executable Versions only under the Mozilla Public License version 2.0 (https://www.mozilla.org/en-US/MPL/2.0/).'

case "$CUSTOM_PREFIX" in
    /*) ;;
    *)
        echo "ERROR: DINOX_CUSTOM_DEPENDENCY_PREFIX must be an absolute path: $CUSTOM_PREFIX" >&2
        exit 2
        ;;
esac
case "$(basename "$CUSTOM_PREFIX")" in
    dinox-deps|dinox-deps-*) ;;
    *)
        echo "ERROR: private dependency directory must be named dinox-deps or dinox-deps-*: $CUSTOM_PREFIX" >&2
        exit 2
        ;;
esac
case "$CUSTOM_LICENSE_ROOT" in
    "$CUSTOM_PREFIX"/*) ;;
    *)
        echo "ERROR: custom dependency licenses must stay below $CUSTOM_PREFIX: $CUSTOM_LICENSE_ROOT" >&2
        exit 2
        ;;
esac
case "$CUSTOM_SOURCE_ROOT" in
    "$CUSTOM_PREFIX"/*) ;;
    *)
        echo "ERROR: corresponding sources must stay below $CUSTOM_PREFIX: $CUSTOM_SOURCE_ROOT" >&2
        exit 2
        ;;
esac
case "$RECORDER_FFMPEG_ROOT" in
    "$CUSTOM_PREFIX"/*) ;;
    *)
        echo "ERROR: recorder ffmpeg must stay below $CUSTOM_PREFIX: $RECORDER_FFMPEG_ROOT" >&2
        exit 2
        ;;
esac

export DINOX_CUSTOM_DEPENDENCY_PREFIX="$CUSTOM_PREFIX"
export DINOX_CUSTOM_DEPENDENCY_LICENSE_ROOT="$CUSTOM_LICENSE_ROOT"
export DINOX_CUSTOM_DEPENDENCY_SOURCE_ROOT="$CUSTOM_SOURCE_ROOT"
export DINOX_RECORDER_FFMPEG_ROOT="$RECORDER_FFMPEG_ROOT"
export PATH="$CUSTOM_BINDIR${PATH:+:$PATH}"
export PKG_CONFIG_PATH="$CUSTOM_LIBDIR/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CMAKE_PREFIX_PATH="$CUSTOM_PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$CUSTOM_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

require_libomemo_additional_permission() {
    local readme="$1"

    [ -s "$readme" ] || {
        echo "ERROR: libomemo-c additional-permission README is missing: $readme" >&2
        exit 1
    }
    printf '%s  %s\n' "$LIBOMEMO_C_README_SHA256" "$readme" | sha256sum -c - >/dev/null \
        || { echo "ERROR: libomemo-c additional-permission README checksum mismatch" >&2; exit 1; }
    grep -Fx "$LIBOMEMO_C_ADDITIONAL_PERMISSION" "$readme" >/dev/null \
        || { echo "ERROR: libomemo-c App Store additional permission is missing from README.md" >&2; exit 1; }
}

stage_dependency_licenses() {
    local component="$1"
    local version="$2"
    local source_url="$3"
    local checksum_algorithm="$4"
    local checksum="$5"
    local source_dir="$6"
    local license_expression="${7:-}"
    local destination="$CUSTOM_LICENSE_ROOT/$component"
    local metadata_file
    local license_count=0

    [ -d "$source_dir" ] || {
        echo "ERROR: source directory for $component licenses is missing: $source_dir" >&2
        exit 1
    }

    metadata_file="$(mktemp)"
    {
        printf 'component=%s\n' "$component"
        printf 'version=%s\n' "$version"
        printf 'source_url=%s\n' "$source_url"
        printf 'checksum_algorithm=%s\n' "$checksum_algorithm"
        printf 'checksum=%s\n' "$checksum"
        if [ -n "$license_expression" ]; then
            printf 'license_expression=%s\n' "$license_expression"
        fi
        if [ "$component" = "libomemo-c" ]; then
            printf 'additional_permission_file=files/README.md\n'
            printf 'additional_permission_sha256=%s\n' "$LIBOMEMO_C_README_SHA256"
        fi
    } > "$metadata_file"

    $SUDO rm -rf "$destination"
    $SUDO install -d -m 0755 "$destination/files"
    $SUDO install -m 0644 "$metadata_file" "$destination/METADATA"
    rm -f "$metadata_file"

    while IFS= read -r -d '' license_file; do
        local relative_path="${license_file#"$source_dir"/}"
        $SUDO install -D -m 0644 \
            "$license_file" "$destination/files/$relative_path"
        license_count=$((license_count + 1))
    done < <(
        find "$source_dir" -type f \
            \( -iname 'LICENSE' -o -iname 'LICENSE.*' -o -iname 'LICENSE-*' \
               -o -iname 'LICENCE' -o -iname 'LICENCE.*' -o -iname 'LICENCE-*' \
               -o -iname 'COPYING' -o -iname 'COPYING.*' -o -iname 'COPYING-*' \
               -o -iname 'COPYRIGHT' -o -iname 'COPYRIGHT.*' -o -iname 'COPYRIGHT-*' \
               -o -iname 'NOTICE' -o -iname 'NOTICE.*' -o -iname 'NOTICE-*' \
               -o -iname 'PATENTS' -o -iname 'PATENTS.*' -o -iname 'PATENTS-*' \) \
            -not -path '*/.git/*' \
            -not -path '*/build/*' \
            -print0
    )

    if [ "$component" = "libomemo-c" ]; then
        require_libomemo_additional_permission "$source_dir/README.md"
        $SUDO install -D -m 0644 \
            "$source_dir/README.md" "$destination/files/README.md"
        license_count=$((license_count + 1))
        require_libomemo_additional_permission "$destination/files/README.md"
    fi

    if [ "$license_count" -eq 0 ]; then
        echo "ERROR: no license files found for $component in $source_dir" >&2
        exit 1
    fi
    echo "Staged $license_count license file(s) for $component $version."
}

stage_corresponding_source() {
    local component="$1"
    local version="$2"
    local source_url="$3"
    local checksum_algorithm="$4"
    local checksum="$5"
    local source_archive="$6"
    local license_expression="$7"
    local destination="$CUSTOM_SOURCE_ROOT/$component"
    local archive_name="$(basename "$source_archive")"
    local metadata_file

    [ -s "$source_archive" ] || {
        echo "ERROR: corresponding source archive for $component is missing: $source_archive" >&2
        exit 1
    }

    case "$checksum_algorithm" in
        sha256)
            printf '%s  %s\n' "$checksum" "$source_archive" | sha256sum -c - >/dev/null
            ;;
        sha512)
            printf '%s  %s\n' "$checksum" "$source_archive" | sha512sum -c - >/dev/null
            ;;
        *)
            echo "ERROR: unsupported source checksum algorithm for $component: $checksum_algorithm" >&2
            exit 1
            ;;
    esac

    metadata_file="$(mktemp)"
    {
        printf 'component=%s\n' "$component"
        printf 'version=%s\n' "$version"
        printf 'source_url=%s\n' "$source_url"
        printf 'archive=%s\n' "$archive_name"
        printf 'checksum_algorithm=%s\n' "$checksum_algorithm"
        printf 'checksum=%s\n' "$checksum"
        printf 'license_expression=%s\n' "$license_expression"
    } > "$metadata_file"

    $SUDO rm -rf "$destination"
    $SUDO install -d -m 0755 "$destination"
    $SUDO install -m 0644 "$metadata_file" "$destination/METADATA"
    $SUDO install -m 0644 "$source_archive" "$destination/$archive_name"
    rm -f "$metadata_file"

    case "$checksum_algorithm" in
        sha256)
            printf '%s  %s\n' "$checksum" "$destination/$archive_name" | sha256sum -c - >/dev/null
            ;;
        sha512)
            printf '%s  %s\n' "$checksum" "$destination/$archive_name" | sha512sum -c - >/dev/null
            ;;
    esac
    echo "Staged exact corresponding source for $component $version."
}

usage() {
    cat <<'USAGE'
Usage:
  ./scripts/ci-build-deps.sh           Build & install all dependencies
  ./scripts/ci-build-deps.sh --clean   Remove previously installed dependencies

CI/container maintainer tool only. It provisions the isolated /opt/dinox-deps
package-builder prefix with root/sudo semantics. Do not use it to prepare a
normal developer workstation; follow docs/internal/BUILD.md instead.

Options:
  -h, --help                           Show this help.
USAGE
}

if [[ "$#" -gt 1 ]]; then
    echo "ERROR: Unknown arguments: $*" >&2
    usage >&2
    exit 2
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
elif [[ -n "${1:-}" && "${1:-}" != "--clean" ]]; then
    echo "ERROR: Unknown argument: $1" >&2
    usage >&2
    exit 2
fi

# Checks if running as root, otherwise use sudo
SUDO=""
if [ "$(id -u)" != "0" ]; then
    SUDO="sudo"
fi

# ---------------------------------------------------------------------------
# --clean mode: remove all previously installed custom dependencies
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--clean" ]]; then
    echo "Cleaning custom-built dependencies..."
    $SUDO rm -rf "$CUSTOM_PREFIX"
    if [[ "$CUSTOM_LICENSE_ROOT" != "$CUSTOM_PREFIX"/* ]]; then
        $SUDO rm -rf "$CUSTOM_LICENSE_ROOT"
    fi
    echo "Custom dependencies removed."
    exit 0
fi

# Build parallelism
NINJA_ARGS=""
MAKE_ARGS="-j$(nproc)"
MESON_OPTS=""
VENDOR_DEPS_URL="https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps"

if [ -n "${DINOX_BUILD_JOBS:-${DINOX_CI_JOBS:-}}" ]; then
    DINOX_EFFECTIVE_JOBS="${DINOX_BUILD_JOBS:-${DINOX_CI_JOBS:-}}"
    if ! [[ "$DINOX_EFFECTIVE_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: invalid DinoX build job limit: $DINOX_EFFECTIVE_JOBS" >&2
        exit 2
    fi
    NINJA_ARGS="-j$DINOX_EFFECTIVE_JOBS"
    MAKE_ARGS="-j$DINOX_EFFECTIVE_JOBS"
fi

download_archive() {
    local output="$1"
    local url="$2"
    local mode="${3:-quiet}"
    local checksum_algo="${4:-}"
    local expected_checksum="${5:-}"
    local tmp="${output}.tmp"

    rm -f "$tmp"
    if [ "$mode" = "progress" ]; then
        if ! wget -O "$tmp" "$url"; then
            rm -f "$tmp"
            return 1
        fi
    else
        if ! wget -q -O "$tmp" "$url"; then
            rm -f "$tmp"
            return 1
        fi
    fi
    mv "$tmp" "$output"
    if [ -n "$expected_checksum" ]; then
        case "$checksum_algo" in
            sha256)
                echo "${expected_checksum}  ${output}" | sha256sum -c -
                ;;
            sha512)
                echo "${expected_checksum}  ${output}" | sha512sum -c -
                ;;
            *)
                echo "ERROR: unsupported checksum algorithm for ${output}: ${checksum_algo:-empty}" >&2
                exit 1
                ;;
        esac
    fi
}

echo "Running Unicode Security Scan..."
if ! python3 scripts/scan_unicode.py; then
    echo "Unicode scan failed! Potential unsafe hidden chars found."
    exit 1
fi

echo "Building dependencies..."
$SUDO rm -rf "$CUSTOM_PREFIX"
$SUDO install -d -m 0755 "$CUSTOM_PREFIX" "$CUSTOM_BINDIR" "$CUSTOM_LIBDIR"

# 1. SQLCipher with FTS5 support
# Ubuntu's libsqlcipher-dev lacks FTS5. Build from source to enable it.
echo "Building SQLCipher with FTS5..."
SQLCIPHER_VER=4.6.1
SQLCIPHER_SHA256=d8f9afcbc2f4b55e316ca4ada4425daf3d0b4aab25f45e11a802ae422b9f53a3
SQLCIPHER_URL="${VENDOR_DEPS_URL}/v${SQLCIPHER_VER}.tar.gz"
download_archive "sqlcipher-${SQLCIPHER_VER}.tar.gz" "$SQLCIPHER_URL" quiet sha256 "$SQLCIPHER_SHA256"
tar xf "sqlcipher-${SQLCIPHER_VER}.tar.gz"
stage_dependency_licenses sqlcipher "$SQLCIPHER_VER" "$SQLCIPHER_URL" sha256 "$SQLCIPHER_SHA256" "$PWD/sqlcipher-${SQLCIPHER_VER}"
cd "sqlcipher-${SQLCIPHER_VER}"
./configure --prefix="$CUSTOM_PREFIX" --libdir="$CUSTOM_LIBDIR" --enable-tempstore=yes --enable-fts5 \
  CFLAGS="-DSQLITE_HAS_CODEC -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_UNLOCK_NOTIFY -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_SOUNDEX -DSQLITE_TEMP_STORE=1" \
  LDFLAGS="-lcrypto"
make $MAKE_ARGS
$SUDO make install
cd ..
rm -rf "sqlcipher-${SQLCIPHER_VER}" "sqlcipher-${SQLCIPHER_VER}.tar.gz"
echo "SQLCipher $(sqlcipher :memory: 'select sqlite_version();' 2>/dev/null) with FTS5 installed."

# 2. libnice
echo "Building libnice..."
LIBNICE_VER=0.1.23
LIBNICE_SHA256=cd69da89d70b529e2eac955de006503a318123d36196482b14005a83e7cb2c21
LIBNICE_URL="${VENDOR_DEPS_URL}/libnice-${LIBNICE_VER}.tar.gz"
download_archive "libnice-${LIBNICE_VER}.tar.gz" "$LIBNICE_URL" progress sha256 "$LIBNICE_SHA256"
tar xf "libnice-${LIBNICE_VER}.tar.gz"
stage_dependency_licenses libnice "$LIBNICE_VER" "$LIBNICE_URL" sha256 "$LIBNICE_SHA256" "$PWD/libnice-${LIBNICE_VER}"
cd "libnice-${LIBNICE_VER}"
meson setup build --prefix="$CUSTOM_PREFIX" --libdir=lib \
  -Dtests=disabled -Dgtk_doc=disabled -Dexamples=disabled \
  -Dintrospection=disabled -Dgstreamer=disabled $MESON_OPTS
ninja -C build $NINJA_ARGS
$SUDO ninja -C build install
cd ..
rm -rf "libnice-${LIBNICE_VER}" "libnice-${LIBNICE_VER}.tar.gz"

# 4. protobuf-c (runtime library only, no compiler — avoids protobuf C++ dependency)
# Ubuntu 24.04 ships 1.4.1 which has a memory corruption bug in protobuf_c_message_unpack()
# fixed in 1.5.1 (PR #703). Build 1.5.2 from source.
echo "Building protobuf-c..."
PROTOBUFC_VER=1.5.2
PROTOBUFC_SHA256=e2c86271873a79c92b58fef7ebf8de1aa0df4738347a8bd5d4e65a80a16d0d24
PROTOBUFC_URL="${VENDOR_DEPS_URL}/protobuf-c-${PROTOBUFC_VER}.tar.gz"
download_archive "protobuf-c-${PROTOBUFC_VER}.tar.gz" "$PROTOBUFC_URL" quiet sha256 "$PROTOBUFC_SHA256"
tar xf "protobuf-c-${PROTOBUFC_VER}.tar.gz"
stage_dependency_licenses protobuf-c "$PROTOBUFC_VER" "$PROTOBUFC_URL" sha256 "$PROTOBUFC_SHA256" "$PWD/protobuf-c-${PROTOBUFC_VER}"
cd "protobuf-c-${PROTOBUFC_VER}"
./configure --prefix="$CUSTOM_PREFIX" --libdir="$CUSTOM_LIBDIR" --disable-protoc
make $MAKE_ARGS
$SUDO make install
cd ..
rm -rf "protobuf-c-${PROTOBUFC_VER}" "protobuf-c-${PROTOBUFC_VER}.tar.gz"
echo "protobuf-c $(pkg-config --modversion libprotobuf-c 2>/dev/null || echo '?') installed."

# 5. libomemo-c
echo "Building libomemo-c..."
LIBOMEMO_C_VER=0.5.1
LIBOMEMO_C_SHA512=ff59565406c51663f2944e9a7c12c5b0e3fa01073039f5161472dd81f59194b1cf2685bc1e0cc930a141bc409b965c5d93313cfc3e0e237250102af3b5e88826
LIBOMEMO_C_URL="https://git.dinox.im/dinoxim/libomemo-c/releases/download/v${LIBOMEMO_C_VER}/libomemo-c-${LIBOMEMO_C_VER}.tar.gz"
download_archive "libomemo-c-${LIBOMEMO_C_VER}.tar.gz" "$LIBOMEMO_C_URL" quiet sha512 "$LIBOMEMO_C_SHA512"
tar xf "libomemo-c-${LIBOMEMO_C_VER}.tar.gz"
stage_dependency_licenses libomemo-c "$LIBOMEMO_C_VER" "$LIBOMEMO_C_URL" sha512 "$LIBOMEMO_C_SHA512" "$PWD/libomemo-c-${LIBOMEMO_C_VER}"
cd "libomemo-c-${LIBOMEMO_C_VER}"
grep -Fx 'Cflags: -I${includedir}/omemo' src/libomemo-c.pc.in >/dev/null \
    || { echo "ERROR: unexpected upstream libomemo-c pkg-config include flags" >&2; exit 1; }
sed -i 's|^Cflags: -I${includedir}/omemo$|Cflags: -I${includedir}|' src/libomemo-c.pc.in
grep -Fx 'Cflags: -I${includedir}' src/libomemo-c.pc.in >/dev/null \
    || { echo "ERROR: failed to correct libomemo-c pkg-config include root" >&2; exit 1; }
mkdir build
cd build
cmake -DCMAKE_INSTALL_PREFIX="$CUSTOM_PREFIX" \
      -DBUILD_SHARED_LIBS=ON \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_C_FLAGS="-I$CUSTOM_PREFIX/include" \
      -DPBC_LIB="$CUSTOM_LIBDIR/libprotobuf-c.so" \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ..
[ -s "$CUSTOM_PREFIX/include/protobuf-c/protobuf-c.h" ] \
    || { echo "ERROR: private protobuf-c header missing before libomemo-c build" >&2; exit 1; }
grep -F -- "-I$CUSTOM_PREFIX/include" src/CMakeFiles/omemo-c.dir/flags.make >/dev/null \
    || { echo "ERROR: libomemo-c compile does not use private protobuf-c headers" >&2; exit 1; }
grep -F -- "$CUSTOM_LIBDIR/libprotobuf-c.so" src/CMakeFiles/omemo-c.dir/link.txt >/dev/null \
    || { echo "ERROR: libomemo-c link does not use private protobuf-c library" >&2; exit 1; }
make $MAKE_ARGS
$SUDO make install
case " $(pkg-config --cflags-only-I libomemo-c) " in
    *" -I$CUSTOM_PREFIX/include "*) ;;
    *) echo "ERROR: installed libomemo-c pkg-config metadata does not expose $CUSTOM_PREFIX/include" >&2; exit 1 ;;
esac
cd ../..
rm -rf "libomemo-c-${LIBOMEMO_C_VER}" "libomemo-c-${LIBOMEMO_C_VER}.tar.gz"

# 6. cJSON (needed by mosquitto's libcommon even with -DWITH_BROKER=OFF)
echo "Building cJSON..."
CJSON_VER=1.7.19
CJSON_SHA256=7fa616e3046edfa7a28a32d5f9eacfd23f92900fe1f8ccd988c1662f30454562
CJSON_URL="${VENDOR_DEPS_URL}/v${CJSON_VER}.tar.gz"
download_archive "cJSON-${CJSON_VER}.tar.gz" "$CJSON_URL" quiet sha256 "$CJSON_SHA256"
tar xf "cJSON-${CJSON_VER}.tar.gz"
stage_dependency_licenses cjson "$CJSON_VER" "$CJSON_URL" sha256 "$CJSON_SHA256" "$PWD/cJSON-${CJSON_VER}"
cd "cJSON-${CJSON_VER}"
cmake -DCMAKE_INSTALL_PREFIX="$CUSTOM_PREFIX" \
      -DENABLE_CJSON_TEST=OFF \
      -DBUILD_SHARED_LIBS=ON \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      .
make $MAKE_ARGS
$SUDO make install
cd ..
rm -rf "cJSON-${CJSON_VER}" "cJSON-${CJSON_VER}.tar.gz"
echo "cJSON ${CJSON_VER} installed."

# 7. mosquitto (client library only — no broker, no CLI tools)
# Ubuntu 24.04 ships 2.0.18; build 2.1.2 for latest security & protocol fixes.
echo "Building mosquitto..."
MOSQUITTO_VER=2.1.2
MOSQUITTO_SHA256=fd905380691ac65ea5a93779e8214941829e3d6e038d5edff9eac5fd74cbed02
MOSQUITTO_URL="${VENDOR_DEPS_URL}/mosquitto-${MOSQUITTO_VER}.tar.gz"
download_archive "mosquitto-${MOSQUITTO_VER}.tar.gz" "$MOSQUITTO_URL" quiet sha256 "$MOSQUITTO_SHA256"
tar xf "mosquitto-${MOSQUITTO_VER}.tar.gz"
stage_dependency_licenses mosquitto "$MOSQUITTO_VER" "$MOSQUITTO_URL" sha256 "$MOSQUITTO_SHA256" "$PWD/mosquitto-${MOSQUITTO_VER}"
cd "mosquitto-${MOSQUITTO_VER}"
cmake -DCMAKE_INSTALL_PREFIX="$CUSTOM_PREFIX" \
      -DWITH_BROKER=OFF \
      -DWITH_CLIENTS=OFF \
      -DWITH_APPS=OFF \
      -DWITH_PLUGINS=OFF \
      -DWITH_TESTS=OFF \
      -DWITH_DOCS=OFF \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      .
make $MAKE_ARGS
$SUDO make install
mosquitto_lib="$(find -L "$CUSTOM_LIBDIR" -maxdepth 1 -name 'libmosquitto.so*' \( -type f -o -type l \) 2>/dev/null | sort | head -1 || true)"
if [ -z "$mosquitto_lib" ]; then
    echo "ERROR: installed libmosquitto shared library was not found." >&2
    exit 1
fi
if ldd "$mosquitto_lib" 2>/dev/null | grep "not found" >/dev/null; then
    echo "ERROR: installed libmosquitto has unresolved runtime dependencies:" >&2
    ldd "$mosquitto_lib" >&2 || true
    exit 1
fi
cd ..
rm -rf "mosquitto-${MOSQUITTO_VER}" "mosquitto-${MOSQUITTO_VER}.tar.gz"
echo "mosquitto $(pkg-config --modversion libmosquitto 2>/dev/null || echo '?') installed."

# 8. Tor (private DinoX Tor binary for packages)
echo "Building Tor..."
TOR_VER=0.4.9.12
TOR_URL="${VENDOR_DEPS_URL}/tor-${TOR_VER}.tar.gz"
TOR_FILE="tor-${TOR_VER}.tar.gz"
TOR_SHA256=c0d307c9dcdaee4848a8ca53e9d6c4ec92823e4f30be12790b0fbddfc6515f5b
download_archive "${TOR_FILE}" "${TOR_URL}" progress sha256 "$TOR_SHA256"
tar xf "${TOR_FILE}"
stage_dependency_licenses tor "$TOR_VER" "$TOR_URL" sha256 "$TOR_SHA256" "$PWD/tor-${TOR_VER}"
cd "tor-${TOR_VER}"
./configure --prefix="$CUSTOM_PREFIX" \
    --disable-asciidoc \
    --disable-manpage \
    --disable-system-torrc \
    --disable-module-relay \
    --disable-unittests
make $MAKE_ARGS
$SUDO make install
if ldd "$CUSTOM_BINDIR/tor" 2>/dev/null | grep "not found" >/dev/null; then
    echo "ERROR: installed Tor binary has unresolved runtime dependencies:" >&2
    ldd "$CUSTOM_BINDIR/tor" >&2 || true
    exit 1
fi
cd ..
rm -rf "tor-${TOR_VER}" "${TOR_FILE}"
echo "$(tor --version | head -1) installed."

# 9. lyrebird (pluggable transport for Tor: obfs4 + WebTunnel)
# Replaces obfs4proxy. Requires Go >= 1.22 from the build environment.
echo "Checking Go for Lyrebird build..."
if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: 'go' not found. Install golang-go >= 1.22 before running this script."
    exit 1
fi
echo "Using Go version: $(go version)"

echo "Building lyrebird..."
LYREBIRD_VER=0.8.1
LYREBIRD_TAG="lyrebird-${LYREBIRD_VER}"
LYREBIRD_URL="${VENDOR_DEPS_URL}/lyrebird-${LYREBIRD_VER}-vendored.tar.gz"
LYREBIRD_FILE="lyrebird-${LYREBIRD_VER}.tar.gz"
LYREBIRD_SHA256=05d87533c66562baae8a0adac6ae7f7401aa08516ea0dfd192a367d2f8645092

download_archive "${LYREBIRD_FILE}" "${LYREBIRD_URL}" quiet sha256 "$LYREBIRD_SHA256"
if ! file "${LYREBIRD_FILE}" | grep -qi 'gzip'; then
    echo "ERROR: downloaded lyrebird archive is not a valid gzip archive."
    rm -f "${LYREBIRD_FILE}"
    exit 1
fi

tar xf "${LYREBIRD_FILE}"
lyrebird_source_dir="$(find . -maxdepth 1 -type d -name "lyrebird-${LYREBIRD_TAG}-*" | sort | head -1)"
[ -n "$lyrebird_source_dir" ] || {
    echo "ERROR: extracted Lyrebird source directory was not found." >&2
    exit 1
}
stage_dependency_licenses lyrebird "$LYREBIRD_VER" "$LYREBIRD_URL" sha256 "$LYREBIRD_SHA256" "$PWD/${lyrebird_source_dir#./}"
cd lyrebird-${LYREBIRD_TAG}-*
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.lyrebirdVersion=${LYREBIRD_VER}" -o lyrebird ./cmd/lyrebird
$SUDO install -m 755 lyrebird "$CUSTOM_BINDIR/lyrebird"
cd ..
rm -rf lyrebird-${LYREBIRD_TAG}-* "${LYREBIRD_FILE}"
echo "lyrebird $(lyrebird --version 2>&1 | head -1) installed."

# 10. Minimal private ffmpeg CLI for AppImage audio/video-message recording.
#
# The Google/libwebrtc runtime carries private dynamic libavcodec/libavutil
# libraries in /usr/lib/dinox.  The recorder therefore links FFmpeg and x264
# statically into this one executable.  It remains dynamically linked only to
# the normal host toolchain ABI and cannot collide with those private SONAMEs.
echo "Building private recorder ffmpeg..."
FFMPEG_RECORDER_VER=8.1.2
FFMPEG_RECORDER_SHA256=464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c
FFMPEG_RECORDER_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_RECORDER_VER}.tar.xz"
FFMPEG_RECORDER_FILE="ffmpeg-${FFMPEG_RECORDER_VER}.tar.xz"
X264_RECORDER_COMMIT=b35605ace3ddf7c1a5d67a2eb553f034aef41d55
X264_RECORDER_SHA256=cd71a7515b0e9a012e1ac9b1f8415bebcaf6fc97d4db32286642ac4c0fbe24f9
X264_RECORDER_URL="https://code.videolan.org/videolan/x264/-/archive/${X264_RECORDER_COMMIT}/x264-${X264_RECORDER_COMMIT}.tar.gz"
X264_RECORDER_FILE="x264-${X264_RECORDER_COMMIT}.tar.gz"
X264_RECORDER_BUILD_PREFIX="$PWD/x264-${X264_RECORDER_COMMIT}-static"

download_archive "$X264_RECORDER_FILE" "$X264_RECORDER_URL" quiet sha256 "$X264_RECORDER_SHA256"
tar xf "$X264_RECORDER_FILE"
stage_dependency_licenses \
    recorder-x264 "$X264_RECORDER_COMMIT" "$X264_RECORDER_URL" sha256 \
    "$X264_RECORDER_SHA256" "$PWD/x264-${X264_RECORDER_COMMIT}" GPL-2.0-or-later
stage_corresponding_source \
    recorder-x264 "$X264_RECORDER_COMMIT" "$X264_RECORDER_URL" sha256 \
    "$X264_RECORDER_SHA256" "$PWD/$X264_RECORDER_FILE" GPL-2.0-or-later
cd "x264-${X264_RECORDER_COMMIT}"
./configure \
    --prefix="$X264_RECORDER_BUILD_PREFIX" \
    --libdir="$X264_RECORDER_BUILD_PREFIX/lib" \
    --enable-static \
    --enable-pic \
    --disable-cli \
    --disable-opencl \
    --bit-depth=8 \
    --chroma-format=420
make $MAKE_ARGS
make install
cd ..

download_archive "$FFMPEG_RECORDER_FILE" "$FFMPEG_RECORDER_URL" progress sha256 "$FFMPEG_RECORDER_SHA256"
tar xf "$FFMPEG_RECORDER_FILE"
stage_dependency_licenses \
    recorder-ffmpeg "$FFMPEG_RECORDER_VER" "$FFMPEG_RECORDER_URL" sha256 \
    "$FFMPEG_RECORDER_SHA256" "$PWD/ffmpeg-${FFMPEG_RECORDER_VER}" GPL-2.0-or-later
stage_corresponding_source \
    recorder-ffmpeg "$FFMPEG_RECORDER_VER" "$FFMPEG_RECORDER_URL" sha256 \
    "$FFMPEG_RECORDER_SHA256" "$PWD/$FFMPEG_RECORDER_FILE" GPL-2.0-or-later
cd "ffmpeg-${FFMPEG_RECORDER_VER}"
PKG_CONFIG_PATH="$X264_RECORDER_BUILD_PREFIX/lib/pkgconfig" \
    ./configure \
        --prefix="$RECORDER_FFMPEG_ROOT" \
        --disable-shared \
        --enable-static \
        --disable-autodetect \
        --disable-everything \
        --disable-doc \
        --disable-debug \
        --disable-network \
        --disable-programs \
        --enable-ffmpeg \
        --enable-small \
        --enable-gpl \
        --enable-libx264 \
        --pkg-config-flags=--static \
        --extra-cflags="-I$X264_RECORDER_BUILD_PREFIX/include" \
        --extra-ldflags="-L$X264_RECORDER_BUILD_PREFIX/lib" \
        --enable-protocol=file,pipe \
        --enable-demuxer=mov,pcm_s16le,rawvideo \
        --enable-muxer=ipod,mov,mp4 \
        --enable-decoder=aac,h264,pcm_s16le,rawvideo \
        --enable-encoder=aac,libx264 \
        --enable-parser=aac,h264 \
        --enable-filter=aformat,anull,aresample,format,null,scale \
        --enable-swresample \
        --enable-swscale
make $MAKE_ARGS ffmpeg
$SUDO install -d -m 0755 "$RECORDER_FFMPEG_ROOT/bin"
$SUDO install -m 0755 ffmpeg "$RECORDER_FFMPEG_ROOT/bin/ffmpeg"
$SUDO strip --strip-unneeded "$RECORDER_FFMPEG_ROOT/bin/ffmpeg"
cd ..

rm -rf \
    "ffmpeg-${FFMPEG_RECORDER_VER}" \
    "$FFMPEG_RECORDER_FILE" \
    "x264-${X264_RECORDER_COMMIT}" \
    "$X264_RECORDER_FILE" \
    "$X264_RECORDER_BUILD_PREFIX"
echo "Private recorder ffmpeg $FFMPEG_RECORDER_VER installed."

echo "Dependencies built and installed."
