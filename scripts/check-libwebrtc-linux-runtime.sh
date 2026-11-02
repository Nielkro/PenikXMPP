#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

fail() { echo "FAIL: $*" >&2; exit 1; }
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVENANCE_CHECK="$PROJECT_ROOT/scripts/libwebrtc-runtime-provenance.py"
vision_runtime=""
arguments=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vision-runtime)
            [[ $# -ge 2 && -n "$2" ]] || fail "--vision-runtime requires a flat bundle directory"
            vision_runtime="$2"; shift 2 ;;
        *) arguments+=("$1"); shift ;;
    esac
done
set -- "${arguments[@]}"
runtime_root="${1:-}"
expected_milestone="${DINOX_LIBWEBRTC_MILESTONE:-152}"
[[ "$expected_milestone" == 150 || "$expected_milestone" == 152 ]] \
    || fail "expected milestone must be 150 (retained runtime) or 152"
if [[ "$#" -ne 1 && "$#" -ne 4 ]]; then
    fail "usage: $0 RUNTIME_ROOT [EXPECTED_WRAPPER_ABI EXPECTED_IPC_PROTOCOL_VERSION EXPECTED_VIDEO_RING_VERSION] [--vision-runtime DIR]"
fi
[[ -n "$runtime_root" && -d "$runtime_root" ]] || fail "runtime root is not a directory: $runtime_root"
# The one-argument form validates the runtime currently pinned by package
# consumers. Runtime builders may pass the contract explicitly while staging a
# future generation before its package pins advance atomically.
expected_wrapper_abi="${2:-40}"
expected_ipc_protocol_version="${3:-10}"
expected_video_ring_version="${4:-6}"
for expected_version in \
    "$expected_wrapper_abi" \
    "$expected_ipc_protocol_version" \
    "$expected_video_ring_version"; do
    [[ "$expected_version" =~ ^[0-9]+$ ]] \
        || fail "expected runtime contract versions must be non-negative integers"
done
[[ "$(uname -m)" == "x86_64" ]] \
    || fail "the published Google/libwebrtc Linux runtime requires an x86_64 host"
for command_name in strings readelf nm ldd; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "$command_name is required to validate the Linux runtime"
done
command -v python3 >/dev/null 2>&1 \
    || fail "python3 is required to validate the Linux runtime"
[[ -f "$PROVENANCE_CHECK" ]] \
    || fail "runtime provenance checker is missing: $PROVENANCE_CHECK"
if (( expected_wrapper_abi >= 40 )); then
    vision_runtime="${vision_runtime:-$runtime_root/lib}"
    # Shipping runtimes must contain their own complete adjacent bundle.
    [[ "$(realpath "$vision_runtime")" == "$(realpath "$runtime_root/lib")" ]] \
        || fail "shipping vision bundle must be inside the runtime lib directory"
    python3 "$PROJECT_ROOT/scripts/check-vision-runtime.py" --base "$vision_runtime" --platform linux
elif [[ -n "$vision_runtime" ]]; then
    python3 "$PROJECT_ROOT/scripts/check-vision-runtime.py" --base "$vision_runtime" --platform linux
fi
avcodec=libavcodec.so.62
avutil=libavutil.so.60
if [[ "$expected_milestone" == 152 ]]; then
    avcodec=libavcodec-dinox-hw.so.62
    avutil=libavutil-dinox-hw.so.60
    python3 "$PROJECT_ROOT/scripts/check-libwebrtc-hardware-dependency.py" "$runtime_root" \
        --manifest FFMPEG-VP8-VAAPI.json --platform linux
fi
for relative in \
    manifest.json LICENSE LICENSE.md PATENTS FFMPEG-LICENSE LIBVA-LICENSE FFMPEG-VP8-VAAPI.json \
    include/dinox_webrtc.h \
    lib/libdinox-google-webrtc.so lib/dinox-webrtc-worker \
    "lib/$avcodec" "lib/$avutil" \
    sources/ffmpeg-8.1.2.tar.xz sources/libva-2.20.0.tar.gz; do
    [[ -s "$runtime_root/$relative" ]] || fail "missing or empty runtime file: $relative"
done
[[ -x "$runtime_root/lib/dinox-webrtc-worker" ]] \
    || fail "runtime worker is not executable: lib/dinox-webrtc-worker"

provenance_arguments=(manifest "$runtime_root/manifest.json")
if [[ -n "${DINOX_LIBWEBRTC_DINOX_SOURCE_COMMIT:-}" ]]; then
    provenance_arguments+=("$DINOX_LIBWEBRTC_DINOX_SOURCE_COMMIT")
fi
python3 "$PROVENANCE_CHECK" "${provenance_arguments[@]}"
if [[ "$expected_milestone" == 152 ]]; then
    # Chromium's built-in decoder uses its own static FFmpeg ABI. Hardware
    # calls use dlsym; direct imports here reveal an unsafe archive link order.
    if nm -D --undefined-only "$runtime_root/lib/libdinox-google-webrtc.so" \
            | grep -E '[[:space:]](av_|avcodec_|avpriv_|avformat_|avutil_|sws_|swr_)' >/dev/null; then
        fail "wrapper directly imports FFmpeg symbols instead of isolating its built-in codec ABI"
    fi
    python3 "$PROJECT_ROOT/scripts/libwebrtc-codec-metadata.py" check "$runtime_root"
    python3 - "$runtime_root" <<'PYCODECS'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text())
codecs = json.loads((root / "WEBRTC-CODECS.json").read_text())
if manifest.get("video_codecs") != codecs:
    raise SystemExit("FAIL: runtime does not embed the validated codec metadata")
PYCODECS
fi


python3 - \
    "$runtime_root/manifest.json" \
    "$runtime_root/FFMPEG-VP8-VAAPI.json" \
    "$expected_wrapper_abi" \
    "$expected_ipc_protocol_version" \
    "$expected_video_ring_version" \
    "$runtime_root/lib/libdinox-google-webrtc.so" <<'PY'
import json, pathlib, sys, os
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
vp8_decoder = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
milestone = int(os.environ.get("DINOX_LIBWEBRTC_MILESTONE", "152"))
pins = {
    150: ("7871", "1f975dfd761af6e5d76d28333191973b258d82a8"),
    152: ("7977", "6f37672d358475cd17544121a12494da454d85fb"),
}
expected = {
    "webrtc_milestone": milestone,
    "webrtc_branch": pins[milestone][0],
    "webrtc_commit": pins[milestone][1],
    "target_os": "linux",
    "target_cpu": "x64",
    "artifact_abi": "dinox-libwebrtc-runtime-v2",
    "ipc_protocol_version": int(sys.argv[4]),
    "video_ring_version": int(sys.argv[5]),
    "wrapper_abi": int(sys.argv[3]),
}
for key, value in expected.items():
    if manifest.get(key) != value:
        raise SystemExit(f"FAIL: manifest {key} is {manifest.get(key)!r}, expected {value!r}")
# The wrapper ABI alone does not identify M150/M152. Verify the embedded build
# identity as well; changing a manifest must not relabel an older binary.
binary = pathlib.Path(sys.argv[6]).read_bytes()
for key in ("webrtc_branch", "webrtc_commit"):
    if expected[key].encode("ascii") + b"\0" not in binary:
        raise SystemExit(f"FAIL: wrapper binary lacks the expected M{milestone} {key}: {expected[key]}")
if manifest.get("vp8_hardware_decoder") != vp8_decoder:
    raise SystemExit("FAIL: runtime does not embed the VP8/VA-API dependency manifest")
vp8_expected = {
    "codec": "VP8",
    "ffmpeg_version": "8.1.2",
    "hardware_api": "VA-API",
    "libva_header_version": "2.20.0",
    "license": "LGPL-2.1-or-later",
    "corresponding_source": "sources/ffmpeg-8.1.2.tar.xz",
    "layout": "dinox-ffmpeg-vp8-vaapi-v2",
    "libva_corresponding_source": "sources/libva-2.20.0.tar.gz",
    "linkage": "dynamic-private",
}
for key, value in (vp8_expected.items() if milestone == 150 else []):
    if vp8_decoder.get(key) != value:
        raise SystemExit(
            f"FAIL: VP8/VA-API runtime {key} is {vp8_decoder.get(key)!r}, expected {value!r}")
PY

LC_ALL=C readelf -h "$runtime_root/lib/libdinox-google-webrtc.so" \
    | grep 'DYN (Shared object file)' >/dev/null \
    || fail "wrapper is not an ELF shared object"
LC_ALL=C readelf -h "$runtime_root/lib/dinox-webrtc-worker" \
    | grep 'DYN (Position-Independent Executable file)' >/dev/null \
    || fail "worker is not a PIE executable"
for binary in \
    "$runtime_root/lib/libdinox-google-webrtc.so" \
    "$runtime_root/lib/dinox-webrtc-worker"; do
    LC_ALL=C readelf -h "$binary" | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' \
        || fail "runtime file is not an x86-64 ELF binary: ${binary#"$runtime_root"/}"
done
readelf -d "$runtime_root/lib/dinox-webrtc-worker" | grep '\$ORIGIN' >/dev/null \
    || fail "worker must discover the sibling wrapper through an ORIGIN runpath"
readelf -d "$runtime_root/lib/dinox-webrtc-worker" \
    | grep 'NEEDED.*libdinox-google-webrtc.so' >/dev/null \
    || fail "worker does not import the sibling DinoX wrapper"
readelf -d "$runtime_root/lib/libdinox-google-webrtc.so" \
    | grep 'NEEDED.*libva.so.2' >/dev/null \
    || fail "wrapper does not import required VA-API runtime libva.so.2"
readelf -d "$runtime_root/lib/$avcodec" \
    | grep 'NEEDED.*libva.so.2' >/dev/null \
    || fail "private libavcodec does not import required VA-API runtime libva.so.2"
readelf -d "$runtime_root/lib/$avutil" \
    | grep 'NEEDED.*libva-drm.so.2' >/dev/null \
    || fail "private libavutil does not import required VA-API DRM runtime libva-drm.so.2"
for library in "$avcodec" "$avutil"; do
    readelf -d "$runtime_root/lib/libdinox-google-webrtc.so" \
        | grep "NEEDED.*$library" >/dev/null \
        || fail "wrapper does not import private FFmpeg runtime $library"
    readelf -d "$runtime_root/lib/$library" \
        | grep 'Library runpath: \[\$ORIGIN\]' >/dev/null \
        || fail "$library must resolve sibling private libraries through ORIGIN"
done
readelf -d "$runtime_root/lib/libdinox-google-webrtc.so" \
    | grep 'Library runpath: \[\$ORIGIN' >/dev/null \
    || fail "wrapper must resolve private FFmpeg through an ORIGIN runpath"
for binary in \
    "$runtime_root/lib/libdinox-google-webrtc.so" \
    "$runtime_root/lib/dinox-webrtc-worker"; do
    if ! ldd_output="$(LD_LIBRARY_PATH="$runtime_root/lib" ldd "$binary" 2>&1)"; then
        printf '%s\n' "$ldd_output" >&2
        fail "ldd could not inspect runtime file: ${binary#"$runtime_root"/}"
    fi
    if grep 'not found' <<< "$ldd_output" >/dev/null; then
        printf '%s\n' "$ldd_output" >&2
        fail "runtime file has unresolved dependencies: ${binary#"$runtime_root"/}"
    fi
done
for symbol in \
    dinox_webrtc_get_build_info \
    dinox_webrtc_context_new \
    dinox_webrtc_context_media_audio_playout_start \
    dinox_webrtc_context_media_audio_playout_push \
    dinox_webrtc_context_media_audio_playout_set_paused \
    dinox_webrtc_context_media_audio_playout_flush \
    dinox_webrtc_context_media_audio_playout_finish \
    dinox_webrtc_context_media_audio_playout_stop \
    dinox_webrtc_video_effect_config_default \
    dinox_webrtc_video_pipeline_callbacks_default \
    dinox_webrtc_context_get_video_effect_capabilities \
    dinox_webrtc_video_pipeline_new \
    dinox_webrtc_video_pipeline_attach_session \
    dinox_webrtc_video_pipeline_detach_session \
    dinox_webrtc_video_pipeline_set_config \
    dinox_webrtc_video_pipeline_get_state \
    dinox_webrtc_video_pipeline_get_diagnostics \
    dinox_webrtc_video_pipeline_free \
    dinox_webrtc_internal_worker_enter; do
    nm -D --defined-only "$runtime_root/lib/libdinox-google-webrtc.so" \
        | grep " $symbol$" >/dev/null \
        || fail "wrapper export missing: $symbol"
done
if (( expected_wrapper_abi >= 39 )); then
    for symbol in \
        dinox_webrtc_session_prepare_local_description \
        dinox_webrtc_session_set_local_description; do
        nm -D --defined-only "$runtime_root/lib/libdinox-google-webrtc.so" \
            | grep " $symbol$" >/dev/null \
            || fail "wrapper export missing: $symbol"
    done
fi
if (( expected_wrapper_abi >= 40 )); then
    for symbol in \
        dinox_webrtc_video_pipeline_background_upload \
        dinox_webrtc_video_pipeline_background_builtin \
        dinox_webrtc_video_pipeline_background_prepare \
        dinox_webrtc_video_pipeline_background_release; do
        nm -D --defined-only "$runtime_root/lib/libdinox-google-webrtc.so" \
            | grep " $symbol$" >/dev/null \
            || fail "ABI40 wrapper export missing: $symbol"
    done
fi
strings "$runtime_root/lib/libdinox-google-webrtc.so" \
    | grep -Fx 'dinox-libwebrtc-runtime-v2' >/dev/null \
    || fail "wrapper build identity is not dinox-libwebrtc-runtime-v2"
if strings "$runtime_root/lib/libdinox-google-webrtc.so" \
        | grep -F 'dinox-libwebrtc-proof-v1' >/dev/null; then
    fail "wrapper still contains the obsolete proof-v1 runtime identity"
fi
echo "OK: pinned Google/libwebrtc M$expected_milestone Linux runtime contains private dynamic FFmpeg and exact corresponding sources"
