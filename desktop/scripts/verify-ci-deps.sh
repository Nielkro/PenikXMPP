#!/bin/bash
set -euo pipefail

MODE="all"
case "$#:${1:-}" in
    0:)
        ;;
    1:--recorder-only)
        MODE="recorder-only"
        ;;
    1:-h|1:--help)
        cat <<'USAGE'
Usage: scripts/verify-ci-deps.sh [--recorder-only]

Without arguments all private package-builder dependencies are verified.
--recorder-only verifies only the private static FFmpeg/x264 recorder,
its real M4A/MP4 writers, licenses and exact corresponding source archives.
USAGE
        exit 0
        ;;
    *)
        echo "ERROR: unsupported arguments: $*" >&2
        exit 2
        ;;
esac

TOR_REQUIRED_VERSION="0.4.9.12"
LYREBIRD_REQUIRED_VERSION="0.8.1"
FFMPEG_RECORDER_REQUIRED_VERSION="8.1.2"
FFMPEG_RECORDER_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
X264_RECORDER_REQUIRED_COMMIT="b35605ace3ddf7c1a5d67a2eb553f034aef41d55"
X264_RECORDER_SHA256="cd71a7515b0e9a012e1ac9b1f8415bebcaf6fc97d4db32286642ac4c0fbe24f9"
LIBOMEMO_C_README_SHA256="83adeac2f4760208e75160502dce8931a9c918151fb4518ce6e3f011abed2057"
LIBOMEMO_C_ADDITIONAL_PERMISSION='Additional Permissions For Submission to Apple App Store: Provided that you are otherwise in compliance with the GPLv3 for each covered work you convey (including without limitation making the Corresponding Source available in compliance with Section 6 of the GPLv3), Open Whisper Systems and Dino Team also grant you the additional permission to convey through the Apple App Store non-source executable versions of the Program as incorporated into each applicable covered work as Executable Versions only under the Mozilla Public License version 2.0 (https://www.mozilla.org/en-US/MPL/2.0/).'
CUSTOM_PREFIX="${DINOX_CUSTOM_DEPENDENCY_PREFIX:-/opt/dinox-deps}"
CUSTOM_BINDIR="$CUSTOM_PREFIX/bin"
CUSTOM_LIBDIR="$CUSTOM_PREFIX/lib"
CUSTOM_LICENSE_ROOT="${DINOX_CUSTOM_DEPENDENCY_LICENSE_ROOT:-$CUSTOM_PREFIX/share/dinox/custom-dependency-licenses}"
CUSTOM_SOURCE_ROOT="${DINOX_CUSTOM_DEPENDENCY_SOURCE_ROOT:-$CUSTOM_PREFIX/share/dinox/corresponding-sources}"
RECORDER_FFMPEG_ROOT="${DINOX_RECORDER_FFMPEG_ROOT:-$CUSTOM_PREFIX/libexec/dinox-recorder-ffmpeg}"
RECORDER_FFMPEG="$RECORDER_FFMPEG_ROOT/bin/ffmpeg"

export PATH="$CUSTOM_BINDIR${PATH:+:$PATH}"
export PKG_CONFIG_PATH="$CUSTOM_LIBDIR/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$CUSTOM_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_file_any() {
    local label="$1"
    shift
    local path

    for path in "$@"; do
        [ -f "$path" ] && {
            echo "OK $label: $path"
            return 0
        }
    done

    fail "$label missing: $*"
}

require_nonempty_file() {
    local label="$1"
    local path="$2"

    [ -s "$path" ] || fail "$label missing or empty: $path"
    echo "OK $label: $path"
}

require_pkg_config() {
    local pc="$1"
    local expected_version="$2"
    local pcfiledir version

    pkg-config --exists "$pc" || fail "pkg-config entry missing: $pc"
    version="$(pkg-config --modversion "$pc" 2>/dev/null || true)"
    [ "$version" = "$expected_version" ] \
        || fail "$pc version ${version:-unknown}, expected $expected_version"
    pcfiledir="$(pkg-config --variable=pcfiledir "$pc" 2>/dev/null || true)"
    [ "$pcfiledir" = "$CUSTOM_LIBDIR/pkgconfig" ] \
        || fail "$pc resolves outside private prefix: ${pcfiledir:-unknown}"
    case " $(pkg-config --libs-only-L "$pc" 2>/dev/null) " in
        *" -L$CUSTOM_LIBDIR "*) ;;
        *) fail "$pc linker flags do not select $CUSTOM_LIBDIR" ;;
    esac
    echo "OK $pc $version from $pcfiledir"
}

require_pkg_config_header() {
    local pc="$1"
    local header="$2"
    local expected_include="$3"
    local probe
    local -a cflags=()

    case " $(pkg-config --cflags-only-I "$pc" 2>/dev/null) " in
        *" -I$expected_include "*) ;;
        *) fail "$pc compiler flags do not expose $expected_include" ;;
    esac
    read -r -a cflags <<< "$(pkg-config --cflags "$pc")"
    probe="$(mktemp --suffix=.o)"
    if ! printf '#include <%s>\nint main(void) { return 0; }\n' "$header" \
            | cc "${cflags[@]}" -x c -c -o "$probe" -; then
        rm -f "$probe"
        fail "$pc public header is not compilable through pkg-config: $header"
    fi
    rm -f "$probe"
    echo "OK $pc public header via $expected_include"
}

require_private_library() {
    local link_name="$1"
    local expected_soname="$2"
    local path="$CUSTOM_LIBDIR/$link_name"
    local real soname

    [ -e "$path" ] || fail "private library missing: $path"
    real="$(realpath -e "$path" 2>/dev/null || true)"
    case "$real" in
        "$CUSTOM_LIBDIR"/*) ;;
        *) fail "$path resolves outside private prefix: ${real:-unknown}" ;;
    esac
    soname="$(readelf -d "$real" 2>/dev/null \
        | sed -n 's/.*Library soname: \[\([^]]*\)\].*/\1/p' \
        | head -1)"
    [ "$soname" = "$expected_soname" ] \
        || fail "$link_name SONAME ${soname:-missing}, expected $expected_soname"
    require_ldd_clean "$real" "$link_name"
    echo "OK $link_name resolves inside $CUSTOM_LIBDIR"
}

require_single_private_payload() {
    local pattern="$1"
    local label="$2"
    local path real
    declare -A payloads=()

    while IFS= read -r -d '' path; do
        real="$(realpath -e "$path" 2>/dev/null || true)"
        [ -n "$real" ] && payloads["$real"]=1
    done < <(find "$CUSTOM_LIBDIR" -maxdepth 1 -name "$pattern" \
        \( -type f -o -type l \) -print0)

    [ "${#payloads[@]}" -eq 1 ] \
        || fail "$label has ${#payloads[@]} real payloads in $CUSTOM_LIBDIR, expected exactly one"
    echo "OK $label has exactly one private payload"
}

require_ldd_clean() {
    local path="$1"
    local label="$2"

    [ -e "$path" ] || fail "$label missing: $path"
    if ldd "$path" 2>/dev/null | grep "not found" >/dev/null; then
        echo "ERROR: unresolved runtime dependencies for $label ($path):" >&2
        ldd "$path" >&2 || true
        exit 1
    fi
    echo "OK $label runtime dependencies resolved"
}

require_version() {
    local path="$1"
    local expected="$2"
    local sed_expr="$3"
    local label="$4"
    local version

    [ -x "$path" ] || fail "$label missing or not executable: $path"
    version="$("$path" --version 2>/dev/null | head -1 | sed -nE "$sed_expr")"
    [ "$version" = "$expected" ] || fail "$label version ${version:-unknown}, expected $expected"
    echo "OK $label $version"
}

require_dependency_licenses() {
    local component="$1"
    local expected_version="$2"
    local expected_url="$3"
    local expected_algorithm="$4"
    local expected_checksum="$5"
    local expected_license_expression="${6:-}"
    local component_root="$CUSTOM_LICENSE_ROOT/$component"
    local license_file

    [ -s "$component_root/METADATA" ] \
        || fail "$component license metadata missing: $component_root/METADATA"
    license_file="$(find "$component_root/files" -type f -size +0c -print -quit 2>/dev/null || true)"
    [ -n "$license_file" ] \
        || fail "$component license files missing below $component_root/files"
    grep -Fx "component=$component" "$component_root/METADATA" >/dev/null \
        || fail "$component license metadata has wrong component"
    grep -Fx "version=$expected_version" "$component_root/METADATA" >/dev/null \
        || fail "$component license metadata has wrong version"
    grep -Fx "source_url=$expected_url" "$component_root/METADATA" >/dev/null \
        || fail "$component license metadata has wrong source URL"
    grep -Fx "checksum_algorithm=$expected_algorithm" "$component_root/METADATA" >/dev/null \
        || fail "$component license metadata has wrong checksum algorithm"
    grep -Fx "checksum=$expected_checksum" "$component_root/METADATA" >/dev/null \
        || fail "$component license metadata has wrong checksum"
    if [ -n "$expected_license_expression" ]; then
        grep -Fx "license_expression=$expected_license_expression" "$component_root/METADATA" >/dev/null \
            || fail "$component license metadata has wrong effective license"
    fi
    if [ "$component" = "libomemo-c" ]; then
        grep -Fx 'additional_permission_file=files/README.md' "$component_root/METADATA" >/dev/null \
            || fail "libomemo-c license metadata does not identify its additional permission"
        grep -Fx "additional_permission_sha256=$LIBOMEMO_C_README_SHA256" \
            "$component_root/METADATA" >/dev/null \
            || fail "libomemo-c license metadata has wrong additional-permission checksum"
        printf '%s  %s\n' "$LIBOMEMO_C_README_SHA256" "$component_root/files/README.md" \
            | sha256sum -c - >/dev/null \
            || fail "libomemo-c additional-permission README checksum mismatch"
        grep -Fx "$LIBOMEMO_C_ADDITIONAL_PERMISSION" "$component_root/files/README.md" >/dev/null \
            || fail "libomemo-c App Store additional permission is not staged"
    fi
    echo "OK $component license material staged"
}

require_corresponding_source() {
    local component="$1"
    local expected_version="$2"
    local expected_url="$3"
    local expected_archive="$4"
    local expected_checksum="$5"
    local component_root="$CUSTOM_SOURCE_ROOT/$component"
    local archive_path="$component_root/$expected_archive"

    [ -s "$component_root/METADATA" ] \
        || fail "$component corresponding-source metadata missing: $component_root/METADATA"
    [ -s "$archive_path" ] \
        || fail "$component corresponding-source archive missing: $archive_path"
    grep -Fx "component=$component" "$component_root/METADATA" >/dev/null \
        || fail "$component source metadata has wrong component"
    grep -Fx "version=$expected_version" "$component_root/METADATA" >/dev/null \
        || fail "$component source metadata has wrong version"
    grep -Fx "source_url=$expected_url" "$component_root/METADATA" >/dev/null \
        || fail "$component source metadata has wrong source URL"
    grep -Fx "archive=$expected_archive" "$component_root/METADATA" >/dev/null \
        || fail "$component source metadata has wrong archive name"
    grep -Fx "checksum_algorithm=sha256" "$component_root/METADATA" >/dev/null \
        || fail "$component source metadata has wrong checksum algorithm"
    grep -Fx "checksum=$expected_checksum" "$component_root/METADATA" >/dev/null \
        || fail "$component source metadata has wrong checksum"
    grep -Fx "license_expression=GPL-2.0-or-later" "$component_root/METADATA" >/dev/null \
        || fail "$component source metadata has wrong effective license"
    printf '%s  %s\n' "$expected_checksum" "$archive_path" | sha256sum -c - >/dev/null \
        || fail "$component corresponding-source archive checksum mismatch"
    echo "OK $component exact corresponding source staged"
}

ffmpeg_capability_present() {
    local output="$1"
    local capability="$2"
    awk -v capability="$capability" \
        '$2 == capability { found = 1 } END { exit(found ? 0 : 1) }' <<< "$output"
}

run_recorder_ffmpeg() {
    local -a command=( "$RECORDER_FFMPEG" "$@" )
    if command -v timeout >/dev/null 2>&1; then
        command=( timeout --kill-after=5s 20s "${command[@]}" )
    fi
    LC_ALL=C LD_LIBRARY_PATH="$CUSTOM_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "${command[@]}"
}

require_recorder_ffmpeg() {
    local version buildconf needed encoders muxers
    local tmp_dir audio_file video_file av_file

    [ -x "$RECORDER_FFMPEG" ] \
        || fail "private recorder ffmpeg missing or not executable: $RECORDER_FFMPEG"
    version="$(LC_ALL=C "$RECORDER_FFMPEG" -version 2>/dev/null | sed -n '1p')"
    case "$version" in
        "ffmpeg version $FFMPEG_RECORDER_REQUIRED_VERSION "*) ;;
        *) fail "private recorder ffmpeg version is not $FFMPEG_RECORDER_REQUIRED_VERSION: ${version:-unknown}" ;;
    esac

    buildconf="$(LC_ALL=C "$RECORDER_FFMPEG" -hide_banner -buildconf 2>&1)" \
        || fail "private recorder ffmpeg build configuration is unreadable"
    local required_flag
    for required_flag in \
        --disable-shared \
        --enable-static \
        --disable-autodetect \
        --disable-everything \
        --disable-network \
        --enable-gpl \
        --enable-libx264; do
        grep -F -- "$required_flag" <<< "$buildconf" >/dev/null \
            || fail "private recorder ffmpeg build flag missing: $required_flag"
    done

    needed="$(LC_ALL=C readelf -d --wide "$RECORDER_FFMPEG" 2>/dev/null \
        | sed -nE 's/.*\(NEEDED\).*\[([^]]+)\].*/\1/p')"
    if grep -Eq '^lib(avcodec|avdevice|avfilter|avformat|avutil|postproc|swresample|swscale|x264)\.so' <<< "$needed"; then
        printf '%s\n' "$needed" >&2
        fail "private recorder ffmpeg dynamically links a private codec library"
    fi
    if find "$RECORDER_FFMPEG_ROOT" -type f \
            \( -name 'libav*.so*' -o -name 'libsw*.so*' -o -name 'libx264.so*' \) \
            -print -quit | grep . >/dev/null; then
        fail "private recorder ffmpeg root contains dynamic codec libraries"
    fi
    require_ldd_clean "$RECORDER_FFMPEG" "private recorder ffmpeg"

    encoders="$(run_recorder_ffmpeg -hide_banner -encoders 2>&1)" \
        || fail "private recorder ffmpeg encoder list is unreadable"
    muxers="$(run_recorder_ffmpeg -hide_banner -muxers 2>&1)" \
        || fail "private recorder ffmpeg muxer list is unreadable"
    ffmpeg_capability_present "$encoders" aac \
        || fail "private recorder ffmpeg AAC encoder missing"
    ffmpeg_capability_present "$encoders" libx264 \
        || fail "private recorder ffmpeg libx264 encoder missing"
    ffmpeg_capability_present "$muxers" ipod \
        || fail "private recorder ffmpeg ipod/M4A muxer missing"
    ffmpeg_capability_present "$muxers" mp4 \
        || fail "private recorder ffmpeg MP4 muxer missing"

    tmp_dir="$(mktemp -d)"
    audio_file="$tmp_dir/audio.m4a"
    video_file="$tmp_dir/video.mp4"
    av_file="$tmp_dir/audio-video.mp4"

    if ! dd if=/dev/zero bs=24000 count=1 2>/dev/null \
            | run_recorder_ffmpeg -hide_banner -loglevel error -y \
                -f s16le -ar 48000 -ac 1 -i pipe:0 -vn \
                -c:a aac -b:a 96000 -movflags +faststart -f ipod "$audio_file"; then
        rm -rf "$tmp_dir"
        fail "private recorder ffmpeg AAC/M4A writer smoke failed"
    fi
    if ! dd if=/dev/zero bs=49152 count=1 2>/dev/null \
            | run_recorder_ffmpeg -hide_banner -loglevel error -y \
                -f rawvideo -pix_fmt bgra -s:v 64x64 -r 5 -i pipe:0 -an \
                -c:v libx264 -preset veryfast -tune zerolatency -profile:v baseline \
                -b:v 300000 -maxrate 300000 -bufsize 600000 \
                -pix_fmt yuv420p -movflags +faststart -f mp4 "$video_file"; then
        rm -rf "$tmp_dir"
        fail "private recorder ffmpeg H.264/MP4 writer smoke failed"
    fi
    if ! run_recorder_ffmpeg -hide_banner -loglevel error -y \
            -i "$video_file" -i "$audio_file" \
            -map 0:v:0 -map 1:a:0 -c copy -shortest \
            -movflags +faststart -f mp4 "$av_file"; then
        rm -rf "$tmp_dir"
        fail "private recorder ffmpeg audio/video remux smoke failed"
    fi
    [ -s "$audio_file" ] || { rm -rf "$tmp_dir"; fail "recorder M4A smoke output is empty"; }
    [ -s "$video_file" ] || { rm -rf "$tmp_dir"; fail "recorder MP4 smoke output is empty"; }
    [ -s "$av_file" ] || { rm -rf "$tmp_dir"; fail "recorder remux smoke output is empty"; }
    rm -rf "$tmp_dir"
    echo "OK private recorder ffmpeg static codec boundary and real M4A/MP4 writers"
}

verify_recorder_payload() {
    require_recorder_ffmpeg
    require_dependency_licenses recorder-ffmpeg 8.1.2 \
        "https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz" sha256 \
        "$FFMPEG_RECORDER_SHA256" GPL-2.0-or-later
    require_dependency_licenses recorder-x264 "$X264_RECORDER_REQUIRED_COMMIT" \
        "https://code.videolan.org/videolan/x264/-/archive/$X264_RECORDER_REQUIRED_COMMIT/x264-$X264_RECORDER_REQUIRED_COMMIT.tar.gz" \
        sha256 "$X264_RECORDER_SHA256" GPL-2.0-or-later
    require_corresponding_source recorder-ffmpeg 8.1.2 \
        "https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz" \
        "ffmpeg-8.1.2.tar.xz" "$FFMPEG_RECORDER_SHA256"
    require_corresponding_source recorder-x264 "$X264_RECORDER_REQUIRED_COMMIT" \
        "https://code.videolan.org/videolan/x264/-/archive/$X264_RECORDER_REQUIRED_COMMIT/x264-$X264_RECORDER_REQUIRED_COMMIT.tar.gz" \
        "x264-$X264_RECORDER_REQUIRED_COMMIT.tar.gz" "$X264_RECORDER_SHA256"
}

if [ "$MODE" = "recorder-only" ]; then
    verify_recorder_payload
    echo "CI private recorder dependency verified."
    exit 0
fi

require_pkg_config sqlcipher 3.46.1
require_pkg_config nice 0.1.23
require_pkg_config libprotobuf-c 1.5.2
require_pkg_config libomemo-c 0.5.1
require_pkg_config_header libomemo-c omemo/curve.h "$CUSTOM_PREFIX/include"
require_pkg_config libcjson 1.7.19
require_pkg_config libmosquitto 2.1.2

require_private_library libsqlcipher.so libsqlcipher.so.0
require_private_library libnice.so libnice.so.10
require_private_library libprotobuf-c.so libprotobuf-c.so.1
require_private_library libomemo-c.so libomemo-c.so.0
require_private_library libcjson.so libcjson.so.1
require_private_library libmosquitto.so libmosquitto.so.1

require_single_private_payload 'libsqlcipher.so*' SQLCipher
require_single_private_payload 'libnice.so*' libnice
require_single_private_payload 'libprotobuf-c.so*' protobuf-c
require_single_private_payload 'libomemo-c.so*' libomemo-c
require_single_private_payload 'libcjson.so*' cJSON
require_single_private_payload 'libmosquitto.so*' Mosquitto

if find "$CUSTOM_PREFIX" -type f -name 'libgstnice.so*' -print -quit \
        | grep . >/dev/null; then
    fail "unused libnice GStreamer plugin is present below private dependency prefix"
fi
echo "OK libnice GStreamer plugin disabled"

[ "$(command -v sqlcipher)" = "$CUSTOM_BINDIR/sqlcipher" ] \
    || fail "sqlcipher executable does not come from $CUSTOM_BINDIR"
if ! "$CUSTOM_BINDIR/sqlcipher" :memory: "pragma compile_options;" 2>/dev/null | grep "ENABLE_FTS5" >/dev/null; then
    fail "SQLCipher was found, but FTS5 support is not enabled"
fi
echo "OK SQLCipher FTS5"
cipher_version="$("$CUSTOM_BINDIR/sqlcipher" :memory: 'pragma cipher_version;' 2>/dev/null | head -1)"
[ "$cipher_version" = "4.6.1 community" ] \
    || fail "SQLCipher cipher_version ${cipher_version:-unknown}, expected 4.6.1 community"
echo "OK SQLCipher cipher_version $cipher_version"

require_version "$CUSTOM_BINDIR/tor" "$TOR_REQUIRED_VERSION" 's/^Tor version ([0-9]+(\.[0-9]+)*).*/\1/p' "Tor"
require_version "$CUSTOM_BINDIR/lyrebird" "$LYREBIRD_REQUIRED_VERSION" 's/^lyrebird ([^[:space:]]+).*/\1/p' "Lyrebird"
require_nonempty_file "Tor GeoIP data" "$CUSTOM_PREFIX/share/tor/geoip"
require_nonempty_file "Tor GeoIPv6 data" "$CUSTOM_PREFIX/share/tor/geoip6"

require_ldd_clean "$CUSTOM_BINDIR/tor" "Tor"

if find "$CUSTOM_PREFIX" -type l ! -exec test -e {} \; -print -quit | grep . >/dev/null; then
    fail "broken symlink below private dependency prefix"
fi
while IFS= read -r -d '' private_symlink; do
    private_target="$(readlink "$private_symlink")"
    case "$private_target" in
        /*) fail "absolute symlink below private dependency prefix: $private_symlink -> $private_target" ;;
    esac
done < <(find "$CUSTOM_PREFIX" -type l -print0)

vendor_url="https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps"
require_dependency_licenses sqlcipher 4.6.1 "$vendor_url/v4.6.1.tar.gz" sha256 d8f9afcbc2f4b55e316ca4ada4425daf3d0b4aab25f45e11a802ae422b9f53a3
require_dependency_licenses libnice 0.1.23 "$vendor_url/libnice-0.1.23.tar.gz" sha256 cd69da89d70b529e2eac955de006503a318123d36196482b14005a83e7cb2c21
require_dependency_licenses protobuf-c 1.5.2 "$vendor_url/protobuf-c-1.5.2.tar.gz" sha256 e2c86271873a79c92b58fef7ebf8de1aa0df4738347a8bd5d4e65a80a16d0d24
require_dependency_licenses libomemo-c 0.5.1 "https://git.dinox.im/dinoxim/libomemo-c/releases/download/v0.5.1/libomemo-c-0.5.1.tar.gz" sha512 ff59565406c51663f2944e9a7c12c5b0e3fa01073039f5161472dd81f59194b1cf2685bc1e0cc930a141bc409b965c5d93313cfc3e0e237250102af3b5e88826
require_dependency_licenses cjson 1.7.19 "$vendor_url/v1.7.19.tar.gz" sha256 7fa616e3046edfa7a28a32d5f9eacfd23f92900fe1f8ccd988c1662f30454562
require_dependency_licenses mosquitto 2.1.2 "$vendor_url/mosquitto-2.1.2.tar.gz" sha256 fd905380691ac65ea5a93779e8214941829e3d6e038d5edff9eac5fd74cbed02
require_dependency_licenses tor 0.4.9.12 "$vendor_url/tor-0.4.9.12.tar.gz" sha256 c0d307c9dcdaee4848a8ca53e9d6c4ec92823e4f30be12790b0fbddfc6515f5b
require_dependency_licenses lyrebird 0.8.1 "$vendor_url/lyrebird-0.8.1-vendored.tar.gz" sha256 05d87533c66562baae8a0adac6ae7f7401aa08516ea0dfd192a367d2f8645092
verify_recorder_payload

echo "CI custom dependencies verified."
