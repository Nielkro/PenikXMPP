#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=8.1.2
SOURCE_SHA256=464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c
PATCH_SHA256=e16236715ae685d9adbabad511aa9c48f96037865d13d9ae0fbc49c3bdcf7672
PATCH="$PROJECT_ROOT/scripts/libwebrtc-ffmpeg-patches/0001-mf-dynamic-bitrate.patch"
fail() { echo "FAIL: $*" >&2; exit 1; }
usage() {
    echo "Usage: $0 --work-dir DIR --output-root DIR --source-archive FILE [--jobs N] [--cross-prefix PREFIX]"
    echo "Builds only shared H.264 Media Foundation/D3D11VA providers; no GPL/nonfree components or software encoder."
}
work=""; output=""; archive=""; jobs=2
cross_prefix=x86_64-w64-mingw32-
while [[ $# -gt 0 ]]; do
    case "$1" in
        --work-dir) work="${2:-}"; shift 2 ;;
        --output-root) output="${2:-}"; shift 2 ;;
        --source-archive) archive="${2:-}"; shift 2 ;;
        --jobs) jobs="${2:-}"; shift 2 ;;
        --cross-prefix) cross_prefix="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ -n "$work" && -n "$output" && -s "$archive" ]] || { usage >&2; exit 2; }
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || fail "invalid job count"
for tool in python3 sha256sum tar make patch "${cross_prefix}gcc" "${cross_prefix}objdump"; do
    command -v "$tool" >/dev/null || fail "missing tool: $tool"
done
work="$(realpath -m "$work")"
output="$(realpath -m "$output")"
archive="$(realpath "$archive")"
[[ ! -e "$output" ]] || fail "output already exists: $output"
mkdir -p "$work"
printf '%s  %s\n' "$SOURCE_SHA256" "$archive" "$PATCH_SHA256" "$PATCH" | sha256sum -c -
source_dir="$work/ffmpeg-$VERSION"
[[ ! -e "$source_dir" ]] || fail "source directory already exists; use a fresh work directory"
tar -xJf "$archive" -C "$work"
patch -d "$source_dir" -p1 --batch < "$PATCH"
args=(
    "--prefix=$output" --enable-cross-compile --target-os=mingw32 --arch=x86_64
    "--cross-prefix=$cross_prefix" --disable-everything --disable-programs
    --disable-doc --disable-debug --disable-network --disable-autodetect
    --disable-gpl --disable-nonfree --enable-shared --disable-static --build-suffix=-dinox-hw
    --disable-x86asm --disable-avdevice --disable-avfilter --disable-avformat
    --disable-swresample --disable-swscale --disable-iconv
    --enable-avcodec --enable-avutil --enable-decoder=h264 --enable-parser=h264
    --enable-hwaccel=h264_d3d11va,h264_d3d11va2 --enable-encoder=h264_mf
    --enable-d3d11va --enable-mediafoundation --enable-w32threads --disable-pthreads
    --extra-ldflags=-static-libgcc
)
(cd "$source_dir" && ./configure "${args[@]}" && make "-j$jobs" && make install)
for component in H264_DECODER H264_PARSER H264_D3D11VA_HWACCEL H264_D3D11VA2_HWACCEL H264_MF_ENCODER; do
    grep -q "^#define CONFIG_${component} 1$" "$source_dir/config_components.h" \
        || fail "required hardware component missing: $component"
done
for component in GPL NONFREE; do
    grep -q "^#define CONFIG_${component} 0$" "$source_dir/config.h" \
        || fail "unexpected $component configuration"
done
if grep -E '^#define CONFIG_[A-Z0-9_]+_ENCODER 1$' "$source_dir/config_components.h" \
        | grep -v '^#define CONFIG_H264_MF_ENCODER 1$'; then
    fail "unexpected additional encoder"
fi
for dll in avcodec-dinox-hw-62.dll avutil-dinox-hw-60.dll; do
    [[ -s "$output/bin/$dll" ]] || fail "expected DLL is missing: $dll"
    "${cross_prefix}objdump" -p "$output/bin/$dll" > "$work/$dll.pe.txt"
done
python3 - "$work" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
allowed = {"avcodec-dinox-hw-62.dll", "avutil-dinox-hw-60.dll", "kernel32.dll", "msvcrt.dll",
           "ucrtbase.dll", "ole32.dll", "oleaut32.dll", "user32.dll", "advapi32.dll",
           "mfplat.dll", "mf.dll", "mfuuid.dll", "mfreadwrite.dll", "propsys.dll",
           "d3d11.dll", "dxgi.dll", "dxva2.dll", "bcrypt.dll", "secur32.dll",
           "ws2_32.dll", "shlwapi.dll", "shell32.dll", "gdi32.dll"}
for report in root.glob("*.dll.pe.txt"):
    names = re.findall(r"DLL Name:\s+(\S+)", report.read_text())
    if not names: raise SystemExit("missing PE imports: " + report.name)
    for name in names:
        if name.lower() not in allowed and not name.lower().startswith("api-ms-win-"):
            raise SystemExit("unshipped non-system DLL dependency: " + name)
PY
mkdir -p "$output/sources"
install -m 0644 "$source_dir/COPYING.LGPLv2.1" "$output/FFMPEG-LICENSE"
install -m 0644 "$archive" "$output/sources/ffmpeg-$VERSION.tar.xz"
install -m 0644 "$PATCH" "$output/sources/ffmpeg-mf-dynamic-bitrate.patch"
python3 - "$output" "$SOURCE_SHA256" "$PATCH_SHA256" "${args[*]}" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
data = {
    "layout": "dinox-ffmpeg-windows-hardware-v1", "target_os": "win", "target_cpu": "x64",
    "ffmpeg_version": "8.1.2", "license": "LGPL-2.1-or-later", "linkage": "dynamic-private",
    "hardware_apis": ["Media Foundation", "D3D11VA"], "codecs": ["H264"],
    "encoders": ["h264_mf"], "decoders": ["h264"], "hwaccels": ["h264_d3d11va", "h264_d3d11va2"],
    "encoder_requires_hw_encoding": True, "dynamic_bitrate": True,
    "corresponding_source": "sources/ffmpeg-8.1.2.tar.xz",
    "source_url": "https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz", "source_sha256": sys.argv[2],
    "patch": "sources/ffmpeg-mf-dynamic-bitrate.patch", "patch_sha256": sys.argv[3],
    "configure": sys.argv[4],
    "libraries": {name: hashlib.sha256((root / "bin" / name).read_bytes()).hexdigest()
                  for name in ["avcodec-dinox-hw-62.dll", "avutil-dinox-hw-60.dll"]},
}
(root / "manifest.json").write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
echo "Prepared $output"
