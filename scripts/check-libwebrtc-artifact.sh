#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

EXPECTED_COMMIT="${DINOX_LIBWEBRTC_COMMIT:-6f37672d358475cd17544121a12494da454d85fb}"
EXPECTED_BRANCH="${DINOX_LIBWEBRTC_BRANCH:-7977}"
EXPECTED_MILESTONE="${DINOX_LIBWEBRTC_MILESTONE:-152}"
EXPECTED_ARTIFACT_ABI="${DINOX_LIBWEBRTC_ARTIFACT_ABI:-dinox-libwebrtc-proof-v1}"

usage() {
    echo "Usage: $0 ARTIFACT_ROOT"
    echo
    echo "Validates the prepared Google/libwebrtc artifact layout used by"
    echo "-Dgoogle-libwebrtc-artifact-root=ARTIFACT_ROOT."
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

ok() {
    echo "OK: $*"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

artifact_root="${1:-}"
if [[ -z "$artifact_root" ]]; then
    usage >&2
    exit 2
fi

[[ -d "$artifact_root" ]] || fail "artifact root is not a directory: $artifact_root"

required_files=(
    "$artifact_root/manifest.json"
    "$artifact_root/LICENSE"
    "$artifact_root/LICENSE.md"
    "$artifact_root/PATENTS"
    "$artifact_root/include/api/create_peerconnection_factory.h"
    "$artifact_root/include/api/peer_connection_interface.h"
    "$artifact_root/include/logging/rtc_event_log/events/rtc_event_ice_candidate_pair.h"
    "$artifact_root/lib/libwebrtc.a"
    "$artifact_root/lib/libwebrtc-dinox-video.a"
    "$artifact_root/lib/libc++.a"
    "$artifact_root/lib/libc++abi.a"
    "$artifact_root/toolchain/libcxx-config/__assertion_handler"
    "$artifact_root/toolchain/libcxx-config/__config_site"
    "$artifact_root/toolchain/libcxx/include/vector"
    "$artifact_root/toolchain/libcxxabi/include/cxxabi.h"
)

for required_file in "${required_files[@]}"; do
    [[ -f "$required_file" ]] || fail "missing required file: $required_file"
done
[[ -s "$artifact_root/LICENSE.md" ]] \
    || fail "generated third-party license file is empty: $artifact_root/LICENSE.md"

manifest_commit="$(
    python3 - "$artifact_root/manifest.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
for key in (
    "webrtc_commit",
    "webrtc_branch",
    "webrtc_milestone",
    "target_os",
    "target_cpu",
    "artifact_abi",
):
    print(data.get(key, ""))
PY
)"
mapfile -t manifest_fields <<< "$manifest_commit"
manifest_commit="${manifest_fields[0]:-}"
manifest_branch="${manifest_fields[1]:-}"
manifest_milestone="${manifest_fields[2]:-}"
manifest_target_os="${manifest_fields[3]:-}"
manifest_target_cpu="${manifest_fields[4]:-}"
manifest_artifact_abi="${manifest_fields[5]:-}"

[[ "$manifest_commit" == "$EXPECTED_COMMIT" ]] \
    || fail "manifest webrtc_commit is '$manifest_commit', expected '$EXPECTED_COMMIT'"

[[ "$manifest_branch" == "$EXPECTED_BRANCH" ]] \
    || fail "manifest webrtc_branch is '$manifest_branch', expected '$EXPECTED_BRANCH'"

[[ "$manifest_milestone" == "$EXPECTED_MILESTONE" ]] \
    || fail "manifest webrtc_milestone is '$manifest_milestone', expected '$EXPECTED_MILESTONE'"

[[ "$manifest_artifact_abi" == "$EXPECTED_ARTIFACT_ABI" ]] \
    || fail "manifest artifact_abi is '$manifest_artifact_abi', expected '$EXPECTED_ARTIFACT_ABI'"

[[ -n "$manifest_target_os" ]] || fail "manifest target_os is empty"
[[ -n "$manifest_target_cpu" ]] || fail "manifest target_cpu is empty"

if (( EXPECTED_MILESTONE >= 152 )); then
    python3 "$PROJECT_ROOT/scripts/libwebrtc-codec-metadata.py" check "$artifact_root"
    python3 - "$artifact_root" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text())
codecs = json.loads((root / "WEBRTC-CODECS.json").read_text())
if manifest.get("video_codecs") != codecs:
    raise SystemExit("FAIL: artifact does not embed the validated codec metadata")
PY
fi

if [[ "$manifest_target_os" == "linux" ]]; then
    avcodec=libavcodec
    avutil=libavutil
    if (( EXPECTED_MILESTONE >= 152 )); then
        avcodec=libavcodec-dinox-hw
        avutil=libavutil-dinox-hw
        python3 "$PROJECT_ROOT/scripts/check-libwebrtc-hardware-dependency.py" \
            "$artifact_root" --manifest FFMPEG-VP8-VAAPI.json --platform linux
    fi
    vp8_required_files=(
        "$artifact_root/FFMPEG-LICENSE"
        "$artifact_root/LIBVA-LICENSE"
        "$artifact_root/FFMPEG-VP8-VAAPI.json"
        "$artifact_root/include/ffmpeg-vp8-vaapi/libavcodec/avcodec.h"
        "$artifact_root/include/ffmpeg-vp8-vaapi/libavutil/hwcontext.h"
        "$artifact_root/include/ffmpeg-vp8-vaapi/libavutil/hwcontext_vaapi.h"
        "$artifact_root/include/ffmpeg-vp8-vaapi/va/va.h"
        "$artifact_root/lib/$avcodec.so"
        "$artifact_root/lib/$avcodec.so.62"
        "$artifact_root/lib/$avutil.so"
        "$artifact_root/lib/$avutil.so.60"
        "$artifact_root/sources/ffmpeg-8.1.2.tar.xz"
        "$artifact_root/sources/libva-2.20.0.tar.gz"
    )
    for required_file in "${vp8_required_files[@]}"; do
        [[ -s "$required_file" ]] || fail "missing VP8/VA-API artifact file: $required_file"
    done
    python3 - "$artifact_root/manifest.json" "$artifact_root/FFMPEG-VP8-VAAPI.json" "$EXPECTED_MILESTONE" <<'PY'
import json
import pathlib
import sys

artifact = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
dependency = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
expected = {
    "codec": "VP8",
    "ffmpeg_version": "8.1.2",
    "hardware_api": "VA-API",
    "corresponding_source": "sources/ffmpeg-8.1.2.tar.xz",
    "layout": "dinox-ffmpeg-vp8-vaapi-v2",
    "libva_header_version": "2.20.0",
    "libva_source_sha256": "117f8d658a5fc9ea406ca80a3eb4ae1d70b15a54807c9ed77199c812bed73b60",
    "license": "LGPL-2.1-or-later",
    "libva_corresponding_source": "sources/libva-2.20.0.tar.gz",
    "linkage": "dynamic-private",
    "source_sha256": "464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c",
}
for key, value in (expected.items() if int(sys.argv[3]) < 152 else []):
    if dependency.get(key) != value:
        raise SystemExit(
            f"FAIL: VP8/VA-API dependency {key} is {dependency.get(key)!r}, expected {value!r}")
if artifact.get("vp8_hardware_decoder") != dependency:
    raise SystemExit("FAIL: artifact does not embed the validated VP8/VA-API manifest")
PY
fi

ok "manifest pins WebRTC M$EXPECTED_MILESTONE branch-heads/$EXPECTED_BRANCH commit $EXPECTED_COMMIT"
ok "manifest target is ${manifest_target_os}/${manifest_target_cpu} with ABI $EXPECTED_ARTIFACT_ABI"
ok "headers, static archives, LICENSE, dependency LICENSE.md and PATENTS are present"
if [[ "$manifest_target_os" == "linux" ]]; then
    ok "private dynamic LGPL FFmpeg hardware codecs and exact sources are pinned"
fi

if [[ "${DINOX_LIBWEBRTC_COMPILE_PROBE:-0}" == "1" ]]; then
    cxx="${CXX:-c++}"
    command -v "$cxx" >/dev/null 2>&1 || fail "C++ compiler not found: $cxx"
    probe_args=(
        -std=c++20
        -I"$artifact_root/include"
        -nostdinc++
        -I"$artifact_root/toolchain/libcxx-config"
        -isystem "$artifact_root/toolchain/libcxx/include"
        -isystem "$artifact_root/toolchain/libcxxabi/include"
        -DABSL_ALLOCATOR_NOTHROW=1
        -DNDEBUG
        -DRTC_ENABLE_VP9
        -DUSE_GLIB=1
        -DUSE_UDEV
        -DWEBRTC_HAVE_SCTP
        -DWEBRTC_INCLUDE_INTERNAL_AUDIO_DEVICE
        -DWEBRTC_LINUX
        -DWEBRTC_POSIX
        -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE
        -D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS
        -D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS
    )
    if "$cxx" --version 2>/dev/null | grep -qi 'clang'; then
        probe_args+=(-Wno-nullability-completeness)
    elif "$cxx" --version 2>/dev/null | grep -qi 'gcc\|g++'; then
        probe_args+=(-fpermissive)
    fi
    printf '%s\n' \
        '#include "api/create_peerconnection_factory.h"' \
        '#include "api/peer_connection_interface.h"' \
        'int main() { return 0; }' \
        | "$cxx" "${probe_args[@]}" -fsyntax-only -x c++ -
    ok "C++ header syntax probe passed"
fi
