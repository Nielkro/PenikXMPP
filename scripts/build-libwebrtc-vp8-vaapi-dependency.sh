#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYMBOL_PATCH="$PROJECT_ROOT/scripts/libwebrtc-ffmpeg-patches/0002-private-elf-symbol-versions.patch"
SYMBOL_PATCH_SHA256="e3630fac46c8459340de0b1eb58916f1f3dada03899bded00bca332486375903"
DEFAULT_VERSION="8.1.2"
DEFAULT_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
DEFAULT_URL="https://ffmpeg.org/releases/ffmpeg-${DEFAULT_VERSION}.tar.xz"
DEFAULT_LIBVA_VERSION="2.20.0"
DEFAULT_LIBVA_SHA256="117f8d658a5fc9ea406ca80a3eb4ae1d70b15a54807c9ed77199c812bed73b60"
DEFAULT_LIBVA_URL="https://github.com/intel/libva/archive/refs/tags/${DEFAULT_LIBVA_VERSION}.tar.gz"
NVCODEC_VERSION="8.1.24.15"
NVCODEC_SHA256="1e1600606cde2c04f5b1a71cb3b2e966b3ffe4e252a6ddec5781151d982e259f"
NVCODEC_URL="https://github.com/FFmpeg/nv-codec-headers/archive/refs/tags/n${NVCODEC_VERSION}.tar.gz"

usage() {
    cat <<'USAGE'
Usage:
  scripts/build-libwebrtc-vp8-vaapi-dependency.sh \
    --work-dir /path/to/work \
    --output-root /path/to/ffmpeg-vp8-vaapi \
    [--source-archive /path/to/ffmpeg.tar.xz] \
    [--libva-source-archive /path/to/libva.tar.gz] \
    [--nvcodec-source-archive /path/to/nv-codec-headers.tar.gz] \
    [--jobs N] [--force] [--dry-run]

  scripts/build-libwebrtc-vp8-vaapi-dependency.sh --self-test

Builds a minimal shared FFmpeg dependency for VP8 VA-API decoding and H.264
VA-API/NVENC encoding and VA-API/NVDEC decoding. No GPL/nonfree components,
software encoder, muxer, demuxer, protocol, program or CUDA toolkit is enabled.
USAGE
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

quote_args() {
    local arg
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
}

run_cmd() {
    if [[ "$dry_run" == true ]]; then
        printf 'DRY-RUN:'
        quote_args "$@"
        printf '\n'
    else
        "$@"
    fi
}

run_in_dir() {
    local directory="$1"
    shift
    if [[ "$dry_run" == true ]]; then
        printf 'DRY-RUN: cd %q &&' "$directory"
        quote_args "$@"
        printf '\n'
    else
        (cd "$directory" && "$@")
    fi
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

abs_path() {
    python3 - "$1" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).expanduser().resolve())
PY
}

run_self_test() {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    local output
    output="$(
        "$0" \
            --work-dir "$tmp/work" \
            --output-root "$tmp/output" \
            --jobs 2 \
            --dry-run
    )"
    grep -q 'ffmpeg-8.1.2.tar.xz' <<< "$output" || fail "self-test missing source pin"
    grep -q 'libva-2.20.0.tar.gz' <<< "$output" || fail "self-test missing libva baseline pin"
    grep -q -- '--enable-decoder=vp8' <<< "$output" || fail "self-test missing VP8 decoder"
    grep -q -- '--enable-hwaccel=vp8_vaapi' <<< "$output" || fail "self-test missing VA-API hwaccel"
    grep -q -- '--enable-encoder=h264_vaapi' <<< "$output" || fail "self-test missing hardware H.264 encoders"
    grep -q -- '--enable-hwaccel=h264_vaapi' <<< "$output" || fail "self-test missing hardware H.264 decoders"
    grep -q -- '--disable-gpl' <<< "$output" || fail "self-test missing GPL exclusion"
    grep -q -- '--disable-nonfree' <<< "$output" || fail "self-test missing nonfree exclusion"
    grep -q -- '--enable-shared' <<< "$output" || fail "self-test missing shared-link policy"
    grep -q -- '--disable-static' <<< "$output" || fail "self-test did not disable static libraries"
    grep -q -- '--disable-avformat' <<< "$output" || fail "self-test did not minimize FFmpeg"
    if grep -q -- '--extra-cflags=-fvisibility=hidden' <<< "$output"; then
        fail "self-test found hidden visibility in a shared FFmpeg build"
    fi
    if "$0" --unknown-option >/dev/null 2>&1; then
        fail "self-test accepted an unknown option"
    fi
    echo "Self-test OK"
}

work_dir=""
output_root=""
source_archive=""
libva_source_archive=""
nvcodec_source_archive=""
jobs="${DINOX_BUILD_JOBS:-${DINOX_CI_JOBS:-}}"
force=false
dry_run=false
version="${DINOX_VP8_VAAPI_FFMPEG_VERSION:-$DEFAULT_VERSION}"
source_sha256="${DINOX_VP8_VAAPI_FFMPEG_SHA256:-$DEFAULT_SHA256}"
source_url="${DINOX_VP8_VAAPI_FFMPEG_URL:-$DEFAULT_URL}"
libva_version="${DINOX_VP8_VAAPI_LIBVA_VERSION:-$DEFAULT_LIBVA_VERSION}"
libva_source_sha256="${DINOX_VP8_VAAPI_LIBVA_SHA256:-$DEFAULT_LIBVA_SHA256}"
libva_source_url="${DINOX_VP8_VAAPI_LIBVA_URL:-$DEFAULT_LIBVA_URL}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --work-dir) work_dir="${2:-}"; shift 2 ;;
        --output-root) output_root="${2:-}"; shift 2 ;;
        --source-archive) source_archive="${2:-}"; shift 2 ;;
        --libva-source-archive) libva_source_archive="${2:-}"; shift 2 ;;
        --nvcodec-source-archive) nvcodec_source_archive="${2:-}"; shift 2 ;;
        --jobs) jobs="${2:-}"; shift 2 ;;
        --force) force=true; shift ;;
        --dry-run) dry_run=true; shift ;;
        --self-test) run_self_test; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[[ -n "$work_dir" && -n "$output_root" ]] || { usage >&2; exit 2; }
[[ -z "$jobs" || "$jobs" =~ ^[1-9][0-9]*$ ]] || fail "invalid job count: $jobs"

require_tool python3
work_dir="$(abs_path "$work_dir")"
output_root="$(abs_path "$output_root")"
if [[ -n "$source_archive" ]]; then
    source_archive="$(abs_path "$source_archive")"
else
    source_archive="$work_dir/ffmpeg-${version}.tar.xz"
fi
source_dir="$work_dir/ffmpeg-${version}"
if [[ -n "$libva_source_archive" ]]; then
    libva_source_archive="$(abs_path "$libva_source_archive")"
else
    libva_source_archive="$work_dir/libva-${libva_version}.tar.gz"
fi
libva_source_dir="$work_dir/libva-${libva_version}"
libva_build_dir="$work_dir/libva-${libva_version}-build"
libva_prefix="$work_dir/libva-${libva_version}-prefix"
nvcodec_source_archive="${nvcodec_source_archive:-$work_dir/nv-codec-headers-n${NVCODEC_VERSION}.tar.gz}"
nvcodec_source_archive="$(abs_path "$nvcodec_source_archive")"
nvcodec_source_dir="$work_dir/nv-codec-headers-n${NVCODEC_VERSION}"
nvcodec_prefix="$work_dir/nv-codec-headers-prefix"

if [[ "$dry_run" == false ]]; then
    for tool in curl sha256sum tar make pkg-config install meson ninja patchelf readelf nm patch; do
        require_tool "$tool"
    done
    pkg-config --exists libdrm \
        || fail "libdrm development files are required to build the pinned libva baseline"
fi

if [[ -e "$output_root" ]]; then
    if [[ "$force" == true ]]; then
        run_cmd rm -rf "$output_root"
    else
        fail "output root exists; use --force to replace it: $output_root"
    fi
fi

run_cmd mkdir -p "$work_dir"
if [[ ! -f "$libva_source_archive" ]]; then
    info "Downloading pinned libva ${libva_version} source"
    run_cmd curl -fsSL "$libva_source_url" -o "$libva_source_archive"
fi
if [[ "$dry_run" == true ]]; then
    printf 'DRY-RUN: echo %q | sha256sum -c -\n' "$libva_source_sha256  $libva_source_archive"
else
    echo "$libva_source_sha256  $libva_source_archive" | sha256sum -c -
fi
run_cmd rm -rf "$libva_source_dir" "$libva_build_dir" "$libva_prefix"
run_cmd tar -xzf "$libva_source_archive" -C "$work_dir"
libva_meson_args=(
    "--prefix=$libva_prefix"
    --libdir=lib
    -Ddisable_drm=false
    -Dwith_x11=no
    -Dwith_glx=no
    -Dwith_wayland=no
    -Dwith_win32=no
    -Denable_docs=false
)
info "Building the pinned libva ${libva_version} compile baseline"
run_cmd meson setup "$libva_build_dir" "$libva_source_dir" "${libva_meson_args[@]}"
libva_compile_command=(meson compile -C "$libva_build_dir")
if [[ -n "$jobs" ]]; then
    libva_compile_command+=(--jobs "$jobs")
fi
run_cmd "${libva_compile_command[@]}"
run_cmd meson install -C "$libva_build_dir"

if [[ ! -f "$nvcodec_source_archive" ]]; then
    run_cmd curl -fsSL "$NVCODEC_URL" -o "$nvcodec_source_archive"
fi
if [[ "$dry_run" == true ]]; then
    printf 'DRY-RUN: echo %q | sha256sum -c -\n' "$NVCODEC_SHA256  $nvcodec_source_archive"
else
    echo "$NVCODEC_SHA256  $nvcodec_source_archive" | sha256sum -c -
fi
run_cmd rm -rf "$nvcodec_source_dir" "$nvcodec_prefix"
run_cmd tar -xzf "$nvcodec_source_archive" -C "$work_dir"
run_in_dir "$nvcodec_source_dir" make "PREFIX=$nvcodec_prefix" install

if [[ ! -f "$source_archive" ]]; then
    [[ "$dry_run" == true || -z "${DINOX_VP8_VAAPI_FFMPEG_SOURCE_ARCHIVE_ONLY:-}" ]] \
        || fail "source archive is missing: $source_archive"
    info "Downloading pinned FFmpeg ${version} source"
    run_cmd curl -fsSL "$source_url" -o "$source_archive"
fi
if [[ "$dry_run" == true ]]; then
    printf 'DRY-RUN: echo %q | sha256sum -c -\n' "$source_sha256  $source_archive"
else
    echo "$source_sha256  $source_archive" | sha256sum -c -
fi

run_cmd rm -rf "$source_dir"
run_cmd tar -xJf "$source_archive" -C "$work_dir"
if [[ "$dry_run" == true ]]; then
    printf 'DRY-RUN: patch -d %q -p1 < %q\n' "$source_dir" "$SYMBOL_PATCH"
else
    echo "$SYMBOL_PATCH_SHA256  $SYMBOL_PATCH" | sha256sum -c -
    patch -d "$source_dir" -p1 --batch < "$SYMBOL_PATCH"
fi

configure_args=(
    "--prefix=$output_root"
    --disable-everything
    --disable-programs
    --disable-doc
    --disable-debug
    --disable-network
    --disable-autodetect
    --disable-gpl
    --disable-nonfree
    --enable-shared
    --build-suffix=-dinox-hw
    --disable-static
    --enable-pic
    --disable-x86asm
    --disable-avdevice
    --disable-avfilter
    --disable-avformat
    --disable-swresample
    --disable-swscale
    --disable-iconv
    --enable-avcodec
    --enable-avutil
    --enable-decoder=vp8
    --enable-decoder=h264
    --enable-parser=h264
    --enable-hwaccel=vp8_vaapi
    --enable-hwaccel=h264_vaapi,h264_nvdec
    --enable-encoder=h264_vaapi,h264_nvenc
    --enable-vaapi
    --enable-ffnvcodec
    --enable-cuda
    --enable-nvenc
    --enable-nvdec
    --enable-pthreads
)

info "Configuring private FFmpeg hardware codec dependency"
run_in_dir "$source_dir" env \
    "PKG_CONFIG_PATH=$libva_prefix/lib/pkgconfig:$nvcodec_prefix/lib/pkgconfig" \
    "LD_LIBRARY_PATH=$libva_prefix/lib" \
    ./configure "${configure_args[@]}"
make_args=()
if [[ -n "$jobs" ]]; then
    make_args+=("-j$jobs")
fi
run_in_dir "$source_dir" make "${make_args[@]}"
run_in_dir "$source_dir" make install

if [[ "$dry_run" == false ]]; then
    [[ -s "$output_root/lib/libavcodec-dinox-hw.so.62" ]] || fail "libavcodec-dinox-hw.so.62 was not installed"
    [[ -s "$output_root/lib/libavutil-dinox-hw.so.60" ]] || fail "libavutil-dinox-hw.so.60 was not installed"
    [[ -e "$output_root/lib/libavcodec-dinox-hw.so" ]] || fail "libavcodec-dinox-hw.so linker name was not installed"
    [[ -e "$output_root/lib/libavutil-dinox-hw.so" ]] || fail "libavutil-dinox-hw.so linker name was not installed"
    [[ -s "$output_root/include/libavcodec/avcodec.h" ]] || fail "FFmpeg headers were not installed"
    patchelf --set-rpath '$ORIGIN' "$output_root/lib/libavcodec-dinox-hw.so.62"
    patchelf --set-rpath '$ORIGIN' "$output_root/lib/libavutil-dinox-hw.so.60"
    readelf -d "$output_root/lib/libavcodec-dinox-hw.so.62" \
        | grep 'Library runpath: \[\$ORIGIN\]' >/dev/null \
        || fail "libavcodec private ORIGIN runpath is missing"
    readelf -d "$output_root/lib/libavutil-dinox-hw.so.60" \
        | grep 'Library runpath: \[\$ORIGIN\]' >/dev/null \
        || fail "libavutil private ORIGIN runpath is missing"
    nm -D --defined-only "$output_root/lib/libavcodec-dinox-hw.so.62" \
        | grep ' avcodec_find_decoder@@' >/dev/null \
        || fail "libavcodec shared API symbols are not exported"
    nm -D --defined-only "$output_root/lib/libavutil-dinox-hw.so.60" \
        | grep ' av_hwdevice_ctx_create@@' >/dev/null \
        || fail "libavutil shared API symbols are not exported"
    grep -q '#define CONFIG_VP8_DECODER 1' "$source_dir/config_components.h" \
        || fail "FFmpeg VP8 decoder is not enabled"
    grep -q '#define CONFIG_VP8_VAAPI_HWACCEL 1' "$source_dir/config_components.h" \
        || fail "FFmpeg VP8 VA-API hwaccel is not enabled"
    for component in H264_DECODER H264_PARSER H264_VAAPI_ENCODER H264_NVENC_ENCODER H264_VAAPI_HWACCEL H264_NVDEC_HWACCEL; do
        grep -q "^#define CONFIG_${component} 1$" "$source_dir/config_components.h" \
            || fail "required hardware codec component is missing: $component"
    done
    if grep -E '^#define CONFIG_[A-Z0-9_]+_ENCODER 1$' "$source_dir/config_components.h" \
            | grep -vE '^#define CONFIG_H264_(VAAPI|NVENC)_ENCODER 1$'; then
        fail "minimal FFmpeg dependency unexpectedly enables another encoder"
    fi
    for component in GPL NONFREE; do
        grep -q "^#define CONFIG_${component} 0$" "$source_dir/config.h" \
            || fail "FFmpeg unexpectedly enabled $component"
    done

    [[ -d "$libva_prefix/include/va" ]] || fail "pinned libva headers were not installed"
    cp -a "$libva_prefix/include/va" "$output_root/include/"
    install -m 0644 "$source_dir/COPYING.LGPLv2.1" "$output_root/LICENSE"
    install -m 0644 "$libva_source_dir/COPYING" "$output_root/LIBVA-LICENSE"
    install -d -m 0755 "$output_root/sources"
    install -m 0644 "$source_archive" "$output_root/sources/ffmpeg-${version}.tar.xz"
    install -m 0644 "$SYMBOL_PATCH" "$output_root/sources/ffmpeg-dinox-symbol-versions.patch"
    for library in libavcodec-dinox-hw.so.62 libavutil-dinox-hw.so.60; do
        readelf --version-info "$output_root/lib/$library" | grep 'DINOX_HW_LIBAVUTIL_60' >/dev/null \
            || fail "private avutil symbol namespace is missing: $library"
    done
    readelf --version-info "$output_root/lib/libavcodec-dinox-hw.so.62" | grep 'DINOX_HW_LIBAVCODEC_62' >/dev/null \
        || fail "private avcodec symbol namespace is missing"
    install -m 0644 "$libva_source_archive" "$output_root/sources/libva-${libva_version}.tar.gz"
    install -m 0644 "$nvcodec_source_archive" "$output_root/sources/nv-codec-headers-n${NVCODEC_VERSION}.tar.gz"
    python3 - "$nvcodec_source_dir" "$output_root/NVIDIA-CODEC-HEADERS-LICENSE" <<'PY'
import pathlib, sys
source, target = map(pathlib.Path, sys.argv[1:])
notices = []
for header in sorted((source / "include/ffnvcodec").glob("*.h")):
    text = header.read_text(encoding="utf-8")
    if not text.startswith("/*") or "*/" not in text:
        raise SystemExit("Missing nv-codec-headers copyright block")
    notices.append(header.name + "\n" + text[:text.index("*/") + 2])
target.write_text("\n\n".join(notices) + "\n", encoding="utf-8")
PY

    python3 - "$output_root/manifest.json" \
        "$version" "$source_url" "$source_sha256" \
        "$libva_version" "$libva_source_url" "$libva_source_sha256" \
        "${configure_args[*]:1}" "$NVCODEC_VERSION" "$NVCODEC_URL" "$NVCODEC_SHA256" "$SYMBOL_PATCH_SHA256" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps({
    "codecs": ["VP8", "H264"],
    "decoders": ["vp8", "h264"],
    "encoders": ["h264_vaapi", "h264_nvenc"],
    "hwaccels": ["vp8_vaapi", "h264_vaapi", "h264_nvdec"],
    "parsers": ["h264"],
    "ffmpeg_version": sys.argv[2],
    "hardware_apis": ["VA-API", "CUDA"],
    "corresponding_source": "sources/ffmpeg-" + sys.argv[2] + ".tar.xz",
    "layout": "dinox-ffmpeg-hardware-codecs-v3",
    "libva_header_version": sys.argv[5],
    "libva_source_url": sys.argv[6],
    "libva_source_sha256": sys.argv[7],
    "license": "LGPL-2.1-or-later",
    "libva_corresponding_source": "sources/libva-" + sys.argv[5] + ".tar.gz",
    "linkage": "dynamic-private",
    "source_sha256": sys.argv[4],
    "source_url": sys.argv[3],
    "configure": sys.argv[8],
    "nvcodec_header_version": sys.argv[9],
    "nvcodec_source_url": sys.argv[10],
    "nvcodec_source_sha256": sys.argv[11],
    "nvcodec_corresponding_source": "sources/nv-codec-headers-n" + sys.argv[9] + ".tar.gz",
    "minimum_nvidia_linux_driver": "390.25",
    "patch": "sources/ffmpeg-dinox-symbol-versions.patch", "patch_sha256": sys.argv[12],
    "elf_symbol_versions": ["DINOX_HW_LIBAVCODEC_62", "DINOX_HW_LIBAVUTIL_60"],
    "libraries": {
        name: hashlib.sha256((path.parent / "lib" / name).read_bytes()).hexdigest()
        for name in ["libavcodec-dinox-hw.so.62", "libavutil-dinox-hw.so.60"]
    },
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
fi

info "Prepared $output_root"
