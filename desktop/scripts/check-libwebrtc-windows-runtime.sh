#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVENANCE_CHECK="$PROJECT_ROOT/scripts/libwebrtc-runtime-provenance.py"
runtime_root="${1:-}"
expected_milestone="${DINOX_LIBWEBRTC_MILESTONE:-152}"
[[ "$expected_milestone" == 150 || "$expected_milestone" == 152 ]] \
    || fail "expected milestone must be 152 or explicit legacy override 150"
if [[ "$#" -ne 1 && "$#" -ne 4 ]]; then
    fail "usage: $0 RUNTIME_ROOT [EXPECTED_WRAPPER_ABI EXPECTED_IPC_PROTOCOL_VERSION EXPECTED_VIDEO_RING_VERSION]"
fi
[[ -n "$runtime_root" ]] || fail "runtime root is required"
[[ -d "$runtime_root" ]] || fail "runtime root is not a directory: $runtime_root"
# Native MinGW binutils cannot open absolute Unicode paths. Keep every input
# relative to this runtime without changing the caller's working directory.
runtime_binutils() (
    cd "$runtime_root" || fail "runtime root is not a directory: $runtime_root"
    "$@"
)
# The one-argument form validates the current source contract. Explicit older
# versions are available only for deliberate historical artifact checks.
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
command -v strings >/dev/null 2>&1 || fail "strings from binutils is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
[[ -f "$PROVENANCE_CHECK" ]] \
    || fail "runtime provenance checker is missing: $PROVENANCE_CHECK"

required=(
    manifest.json
    LICENSE
    LICENSE.md
    PATENTS
    bin/dinox-google-webrtc.dll
    bin/dinox-webrtc-worker.exe
    bin/dinox-webrtc-process-engine-smoke.exe
    bin/dinox-webrtc-ipc-protocol-smoke.exe
    bin/dinox-webrtc-video-ring-smoke.exe
    lib/libdinox-google-webrtc.dll.a
)
if (( expected_wrapper_abi >= 39 )); then
    required+=(bin/dinox-webrtc-muji-sdp-smoke.exe)
fi
if (( expected_wrapper_abi >= 40 )); then
    required+=(
        bin/dinox-webrtc-video-effects-smoke.exe
        bin/dinox-webrtc-video-pipeline-effects-smoke.exe
        bin/dinox-webrtc-video-pipeline-privacy-smoke.exe
        bin/dinox-webrtc-video-background-api-smoke.exe
        bin/dinox-webrtc-video-vision-geometry-golden.exe
        bin/dinox-webrtc-vision-fake-worker.exe
        bin/dinox-webrtc-video-effects-baseline.exe
    )
fi
if [[ "$expected_milestone" == 152 ]]; then
    required+=(bin/dinox-webrtc-windows-codec-provider-smoke.exe bin/dinox-webrtc-video-codec-smoke.exe)
fi
for relative in "${required[@]}"; do
    [[ -s "$runtime_root/$relative" ]] || fail "missing or empty runtime file: $relative"
done
if (( expected_wrapper_abi >= 40 )); then
    python3 "$PROJECT_ROOT/scripts/check-vision-runtime.py" --base "$runtime_root/bin" --platform windows
    python3 - "$runtime_root" <<'PYVISION'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
vision = json.loads((root / "bin/dinox-vision-runtime-manifest.json").read_text(encoding="utf-8"))
expected = {"manifest": "bin/dinox-vision-runtime-manifest.json", "payload_id": vision["payload_id"]}
if manifest.get("vision_runtime") != expected:
    raise SystemExit("FAIL: runtime does not embed the matched Windows vision package identity")
PYVISION
fi

provenance_arguments=(manifest "$runtime_root/manifest.json")
if [[ -n "${DINOX_LIBWEBRTC_DINOX_SOURCE_COMMIT:-}" ]]; then
    provenance_arguments+=("$DINOX_LIBWEBRTC_DINOX_SOURCE_COMMIT")
fi
python3 "$PROVENANCE_CHECK" "${provenance_arguments[@]}"
if [[ "$expected_milestone" == 152 ]]; then
    [[ -s "$runtime_root/FFMPEG-LICENSE" ]] || fail "private FFmpeg license is missing"
    python3 "$PROJECT_ROOT/scripts/check-libwebrtc-hardware-dependency.py" "$runtime_root" \
        --manifest FFMPEG-WINDOWS-HARDWARE.json --platform windows
    python3 "$PROJECT_ROOT/scripts/libwebrtc-codec-metadata.py" check "$runtime_root"
    python3 - "$runtime_root" <<'PYCODECS'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text())
codecs = json.loads((root / "WEBRTC-CODECS.json").read_text())
hardware = json.loads((root / "FFMPEG-WINDOWS-HARDWARE.json").read_text())
if manifest.get("windows_hardware_codecs") != hardware:
    raise SystemExit("FAIL: runtime does not embed the validated Windows hardware codec metadata")
if manifest.get("video_codecs") != codecs:
    raise SystemExit("FAIL: runtime does not embed the validated codec metadata")
PYCODECS
fi


python3 - \
    "$runtime_root/manifest.json" \
    "$expected_wrapper_abi" \
    "$expected_ipc_protocol_version" \
    "$expected_video_ring_version" \
    "$runtime_root/bin/dinox-google-webrtc.dll" <<'PY'
import json
import os
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
milestone = int(os.environ.get("DINOX_LIBWEBRTC_MILESTONE", "152"))
pins = {
    150: ("7871", "1f975dfd761af6e5d76d28333191973b258d82a8"),
    152: ("7977", "6f37672d358475cd17544121a12494da454d85fb"),
}
expected = {
    "webrtc_milestone": milestone,
    "webrtc_branch": pins[milestone][0],
    "webrtc_commit": pins[milestone][1],
    "target_os": "win",
    "target_cpu": "x64",
    "artifact_abi": "dinox-libwebrtc-runtime-v2",
    "ipc_protocol_version": int(sys.argv[3]),
    "video_ring_version": int(sys.argv[4]),
    "wrapper_abi": int(sys.argv[2]),
}
for key, value in expected.items():
    if manifest.get(key) != value:
        raise SystemExit(f"FAIL: manifest {key} is {manifest.get(key)!r}, expected {value!r}")
# ABI 39 is shared by M150 and M152. Inspect the embedded narrow-string build
# identity without executing Windows code or accepting a manifest-only bump.
binary = pathlib.Path(sys.argv[5]).read_bytes()
for key in ("webrtc_branch", "webrtc_commit"):
    if expected[key].encode("ascii") + b"\0" not in binary:
        raise SystemExit(f"FAIL: wrapper binary lacks the expected M{milestone} {key}: {expected[key]}")
PY

if command -v objdump >/dev/null 2>&1; then
    runtime_binutils objdump -p bin/dinox-google-webrtc.dll 2>/dev/null \
        | grep 'DLL Name\|Export Address Table' >/dev/null \
        || fail "wrapper DLL is not recognized as a PE runtime"
    runtime_binutils objdump -p bin/dinox-webrtc-worker.exe 2>/dev/null \
        | grep 'DLL Name\|Characteristics' >/dev/null \
        || fail "worker is not recognized as a PE executable"
    runtime_binutils objdump -p bin/dinox-webrtc-worker.exe 2>/dev/null \
        | grep -F 'DLL Name: dinox-google-webrtc.dll' >/dev/null \
        || fail "worker does not import the sibling DinoX wrapper DLL"
    runtime_binutils objdump -p bin/dinox-webrtc-process-engine-smoke.exe 2>/dev/null \
        | grep -F 'DLL Name: dinox-google-webrtc.dll' >/dev/null \
        || fail "process smoke does not import the DinoX wrapper DLL"
    if (( expected_wrapper_abi >= 39 )); then
        runtime_binutils objdump -p bin/dinox-webrtc-muji-sdp-smoke.exe 2>/dev/null \
            | grep -F 'DLL Name: dinox-google-webrtc.dll' >/dev/null \
            || fail "MUJI media smoke does not import the DinoX wrapper DLL"
    fi
fi

if command -v nm >/dev/null 2>&1; then
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
        runtime_binutils nm lib/libdinox-google-webrtc.dll.a \
            | grep "${symbol}$" >/dev/null \
            || fail "wrapper import symbol missing: $symbol"
    done
fi

if (( expected_wrapper_abi >= 39 )); then
    command -v nm >/dev/null 2>&1 || fail "nm is required to validate the MUJI C ABI import library"
    for symbol in \
        dinox_webrtc_session_prepare_local_description \
        dinox_webrtc_session_set_local_description; do
        runtime_binutils nm -g lib/libdinox-google-webrtc.dll.a \
            | grep -E "[[:space:]]${symbol}$" >/dev/null \
            || fail "MinGW import library symbol missing: $symbol"
    done
fi
if (( expected_wrapper_abi >= 40 )); then
    command -v nm >/dev/null 2>&1 || fail "nm is required to validate the video background C ABI import library"
    for symbol in \
        dinox_webrtc_video_pipeline_background_upload \
        dinox_webrtc_video_pipeline_background_builtin \
        dinox_webrtc_video_pipeline_background_prepare \
        dinox_webrtc_video_pipeline_background_release; do
        runtime_binutils nm -g lib/libdinox-google-webrtc.dll.a \
            | grep -E "[[:space:]]${symbol}$" >/dev/null \
            || fail "MinGW video background import symbol missing: $symbol"
    done
fi

runtime_binutils strings bin/dinox-google-webrtc.dll \
    | grep -Fx 'dinox-libwebrtc-runtime-v2' >/dev/null \
    || fail "wrapper build identity is not dinox-libwebrtc-runtime-v2"
if runtime_binutils strings bin/dinox-google-webrtc.dll \
        | grep -F 'dinox-libwebrtc-proof-v1' >/dev/null; then
    fail "wrapper still contains the obsolete proof-v1 runtime identity"
fi

echo "OK: pinned Google/libwebrtc M$expected_milestone Windows runtime and C ABI import library are present"
