#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVENANCE_CHECK="$PROJECT_ROOT/scripts/libwebrtc-runtime-provenance.py"
PIN_COMMIT="6f37672d358475cd17544121a12494da454d85fb"
TOOLCHAIN_HASH="${DINOX_WIN_TOOLCHAIN_HASH:-1d17754806}"
UPSTREAM_TOOLCHAIN_HASH="e66617bc68"
RUNTIME_ARCHIVE_ROOT="libwebrtc-m152-windows-x86_64-runtime"

usage() {
    cat <<'USAGE'
Usage: scripts/build-libwebrtc-windows-runtime.sh \
  --webrtc-src /path/to/webrtc/src \
  --toolchain-cache /path/containing/HASH.zip \
  --runtime-root /path/to/libwebrtc-m152-windows-x86_64-runtime \
  --codec-sources /path/to/published-webrtc-m152-codec-sources.tar.gz \
  --ffmpeg-root /path/to/private-windows-hardware-codecs \
  --vision-runtime /path/to/vision-package/runtime-staging \
  [--build-out /path/to/out] [--jobs N] [--force] [--skip-sync]

Builds the pinned native Windows wrapper DLL, worker EXE and process smoke test
from a Linux dependency-builder. The existing, matched Windows vision worker,
models and original licenses are required; this script never downloads them.
The MSVC/SDK toolchain ZIP is consumed by
Chromium's normal win_toolchain integration; it is not shipped to users.
USAGE
}

fail() { echo "FAIL: $*" >&2; exit 1; }
info() { echo "==> $*"; }
abs_path() { python3 - "$1" <<'PY'
import pathlib, sys
print(pathlib.Path(sys.argv[1]).expanduser().resolve())
PY
}

webrtc_src=""
toolchain_cache=""
runtime_root=""
codec_sources=""
ffmpeg_root=""
vision_runtime=""
build_out=""
jobs="${DINOX_BUILD_JOBS:-}"
force=false
skip_sync=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --webrtc-src) webrtc_src="${2:-}"; shift 2 ;;
        --toolchain-cache) toolchain_cache="${2:-}"; shift 2 ;;
        --runtime-root) runtime_root="${2:-}"; shift 2 ;;
        --codec-sources) codec_sources="${2:-}"; shift 2 ;;
        --ffmpeg-root) ffmpeg_root="${2:-}"; shift 2 ;;
        --vision-runtime) vision_runtime="${2:-}"; shift 2 ;;
        --build-out) build_out="${2:-}"; shift 2 ;;
        --jobs) jobs="${2:-}"; shift 2 ;;
        --force) force=true; shift ;;
        --skip-sync) skip_sync=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[[ -n "$webrtc_src" && -n "$toolchain_cache" && -n "$runtime_root" ]] || { usage >&2; exit 2; }
[[ -s "$codec_sources" ]] || fail "--codec-sources must name the published M152 codec source archive"
[[ -d "$ffmpeg_root/include/libavcodec" ]] || fail "--ffmpeg-root must contain the Windows hardware codec dependency"
[[ -n "$vision_runtime" && -d "$vision_runtime" ]] \
    || fail "--vision-runtime must name the matched Windows vision package runtime-staging directory"
python3 "$PROJECT_ROOT/scripts/check-vision-runtime.py" --base "$vision_runtime" --platform windows
python3 "$PROJECT_ROOT/scripts/check-libwebrtc-hardware-dependency.py" "$ffmpeg_root" --platform windows
[[ -z "$jobs" || "$jobs" =~ ^[1-9][0-9]*$ ]] || fail "invalid job count: $jobs"
for tool in git python3 rsync sha256sum zip; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done
[[ -f "$PROVENANCE_CHECK" ]] || fail "runtime provenance checker is missing: $PROVENANCE_CHECK"
dinox_source_commit="$(python3 "$PROVENANCE_CHECK" source-commit "$PROJECT_ROOT")"
if [[ "$(uname -s)" == "Linux" ]]; then
    for tool in find findmnt flock mountpoint; do
        command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
    done
fi

webrtc_src="$(abs_path "$webrtc_src")"
toolchain_cache="$(abs_path "$toolchain_cache")"
runtime_root="$(abs_path "$runtime_root")"
codec_sources="$(abs_path "$codec_sources")"
ffmpeg_root="$(abs_path "$ffmpeg_root")"
vision_runtime="$(abs_path "$vision_runtime")"
[[ "$vision_runtime" != "$runtime_root" && "$vision_runtime" != "$runtime_root/"* ]] \
    || fail "--vision-runtime must be outside the output runtime root"
[[ "$(basename "$runtime_root")" == "$RUNTIME_ARCHIVE_ROOT" ]] \
    || fail "runtime root basename must be $RUNTIME_ARCHIVE_ROOT"
[[ -d "$webrtc_src/.git" ]] || fail "not a WebRTC checkout: $webrtc_src"
[[ -f "$toolchain_cache/$TOOLCHAIN_HASH.zip" ]] || fail "toolchain ZIP missing: $toolchain_cache/$TOOLCHAIN_HASH.zip"
[[ "$(git -C "$webrtc_src" rev-parse HEAD)" == "$PIN_COMMIT" ]] || fail "WebRTC checkout is not at the DinoX M152 pin"
if [[ -z "$build_out" ]]; then build_out="$webrtc_src/out/m152-win-x64"; fi
build_out="$(abs_path "$build_out")"

export PATH="$(dirname "$webrtc_src")/depot_tools:$webrtc_src/third_party/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0
export "GYP_MSVS_HASH_${UPSTREAM_TOOLCHAIN_HASH}=$TOOLCHAIN_HASH"
export DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL="$toolchain_cache"
GN_BIN="$webrtc_src/buildtools/linux64/gn"
[[ -x "$GN_BIN" ]] || fail "WebRTC GN binary not found: $GN_BIN"
llvm_bin="$webrtc_src/third_party/llvm-build/Release+Asserts/bin"
[[ -x "$llvm_bin/llvm-readobj" ]] || fail "WebRTC llvm-readobj not found: $llvm_bin/llvm-readobj"
dlltool="$llvm_bin/llvm-dlltool"
if [[ ! -x "$dlltool" ]]; then
    dlltool="$(command -v llvm-dlltool || command -v x86_64-w64-mingw32-dlltool || true)"
fi
[[ -n "$dlltool" && -x "$dlltool" ]] \
    || fail "llvm-dlltool or x86_64-w64-mingw32-dlltool is required to create the MinGW import library"
siso="$webrtc_src/third_party/siso/cipd/siso"
[[ -x "$siso" ]] || fail "pinned Siso executable missing: $siso"
if [[ "$skip_sync" == false ]]; then
    command -v gclient >/dev/null 2>&1 || fail "required depot_tools command not found: gclient"
fi

ensure_windows_toolchain_mount() (
    [[ "$(uname -s)" == "Linux" ]] || return 0

    local toolchain_parent="$webrtc_src/third_party/depot_tools/win_toolchain"
    local toolchain_view="$toolchain_parent/vs_files"
    local toolchain_backing="$toolchain_view.ciopfs"
    local ciopfs="$webrtc_src/build/ciopfs"
    local backing_marker="$toolchain_backing/$TOOLCHAIN_HASH/windows kits/10/bin/setenv.x86.json"
    local mounted_marker="$toolchain_view/$TOOLCHAIN_HASH/Windows Kits/10/bin/SetEnv.x86.json"
    local lock_file="$(dirname "$webrtc_src")/.dinox-win-toolchain-ciopfs.lock"
    local lock_fd
    local filesystem_type

    exec {lock_fd}>"$lock_file"
    flock -w 30 "$lock_fd" \
        || fail "timed out waiting for the Windows toolchain mount lock: $lock_file"
    trap 'flock -u "$lock_fd" 2>/dev/null || true; exec {lock_fd}>&-' EXIT

    if mountpoint -q "$toolchain_view"; then
        filesystem_type="$(findmnt -n -o FSTYPE -T "$toolchain_view")"
        [[ "$filesystem_type" == "fuse.ciopfs" ]] \
            || fail "Windows toolchain view uses unexpected filesystem: $filesystem_type"
        [[ -r "$mounted_marker" ]] \
            || fail "mounted Windows toolchain view is incomplete: $mounted_marker"
        return 0
    fi

    [[ -x "$ciopfs" ]] || fail "WebRTC ciopfs helper is missing or not executable: $ciopfs"
    [[ -d "$toolchain_backing/$TOOLCHAIN_HASH" ]] \
        || fail "extracted Windows toolchain backing is missing: $toolchain_backing/$TOOLCHAIN_HASH"
    [[ -r "$backing_marker" ]] \
        || fail "extracted Windows toolchain backing is incomplete: $backing_marker"
    mkdir -p "$toolchain_view"
    [[ -z "$(find "$toolchain_view" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
        || fail "unmounted Windows toolchain view is not empty: $toolchain_view"

    info "Restoring the case-insensitive Windows toolchain view"
    # ciopfs daemonizes. Do not let its daemon inherit and retain our lock FD.
    if ! "$ciopfs" -o use_ino "$toolchain_backing" "$toolchain_view" {lock_fd}>&-; then
        mountpoint -q "$toolchain_view" \
            || fail "could not mount the existing Windows toolchain with ciopfs"
    fi
    mountpoint -q "$toolchain_view" \
        || fail "ciopfs returned without mounting the Windows toolchain view"
    filesystem_type="$(findmnt -n -o FSTYPE -T "$toolchain_view")"
    [[ "$filesystem_type" == "fuse.ciopfs" ]] \
        || fail "restored Windows toolchain view uses unexpected filesystem: $filesystem_type"
    [[ -r "$mounted_marker" ]] \
        || fail "restored Windows toolchain view is incomplete: $mounted_marker"
)

if [[ "$skip_sync" == false ]]; then
    info "Synchronizing Windows dependencies and the pinned MSVC/SDK toolchain"
    (cd "$(dirname "$webrtc_src")" && gclient sync --force --revision "src@$PIN_COMMIT")
fi

# The toolchain is stored behind a ciopfs case-insensitive view. A server
# reboot removes only that FUSE mount, not the extracted toolchain. Restore the
# existing view here so --skip-sync never triggers a multi-gigabyte re-download.
ensure_windows_toolchain_mount

info "Staging the DinoX GN target inside the external WebRTC checkout"
rm -rf "$webrtc_src/dinox_wrapper"
mkdir -p "$webrtc_src/dinox_wrapper"
rsync -a "$PROJECT_ROOT/google-webrtc/include/" "$webrtc_src/dinox_wrapper/include/"
rsync -a "$PROJECT_ROOT/google-webrtc/src/" "$webrtc_src/dinox_wrapper/src/"
mkdir -p "$webrtc_src/dinox_wrapper/vision"
# The optional client is part of the wrapper. Inference itself remains in
# the separate, pinned vision worker and never links into the call engine.
for vision_source in vision_client.hpp vision_client.cpp vision_protocol.hpp face_decoder.hpp \
        vision_process.hpp vision_process_windows.cpp vision_client_fake_worker.cpp; do
    cp "$PROJECT_ROOT/google-webrtc/vision/$vision_source" "$webrtc_src/dinox_wrapper/vision/"
done
rsync -a "$ffmpeg_root/include/" "$webrtc_src/dinox_wrapper/ffmpeg-windows-hardware/"
mkdir -p "$webrtc_src/dinox_wrapper/tests"
cp "$PROJECT_ROOT/google-webrtc/tests/process_engine_smoke.cpp" "$webrtc_src/dinox_wrapper/tests/"
cp "$PROJECT_ROOT/google-webrtc/tests/ipc_protocol_smoke.cpp" "$webrtc_src/dinox_wrapper/tests/"
cp "$PROJECT_ROOT/google-webrtc/tests/video_ring_smoke.cpp" "$webrtc_src/dinox_wrapper/tests/"
cp "$PROJECT_ROOT/google-webrtc/tests/video_effects_smoke.cpp" "$webrtc_src/dinox_wrapper/tests/"
cp "$PROJECT_ROOT/google-webrtc/tests/video_pipeline_effects_smoke.cpp" "$webrtc_src/dinox_wrapper/tests/"
cp "$PROJECT_ROOT/google-webrtc/tests/video_pipeline_privacy_smoke.cpp" "$webrtc_src/dinox_wrapper/tests/"
cp "$PROJECT_ROOT/google-webrtc/tests/video_background_api_smoke.cpp" "$webrtc_src/dinox_wrapper/tests/"
cp "$PROJECT_ROOT/google-webrtc/tests/video_vision_geometry_golden.cpp" "$webrtc_src/dinox_wrapper/tests/"
cp "$PROJECT_ROOT/google-webrtc/tests/video_effects_baseline.cpp" "$webrtc_src/dinox_wrapper/tests/"
cp "$PROJECT_ROOT/google-webrtc/tests/video_codec_smoke.cpp" "$webrtc_src/dinox_wrapper/tests/"
cp "$PROJECT_ROOT/google-webrtc/tests/windows_codec_provider_smoke.cpp" "$webrtc_src/dinox_wrapper/tests/"
cp "$PROJECT_ROOT/google-webrtc/tests/wrapper_smoke.cpp" "$webrtc_src/dinox_wrapper/tests/"
cp "$PROJECT_ROOT/scripts/libwebrtc-windows-runtime/BUILD.gn" "$webrtc_src/dinox_wrapper/BUILD.gn"

# Upstream intentionally restricts its complete static archive to two root
# targets. Temporarily grant only the isolated DinoX wrapper directory access;
# restore the pinned checkout even when GN or Ninja fails.
upstream_build_backup="$(mktemp)"
cp "$webrtc_src/BUILD.gn" "$upstream_build_backup"
restore_upstream_build() {
    cp "$upstream_build_backup" "$webrtc_src/BUILD.gn"
    rm -f "$upstream_build_backup"
}
trap restore_upstream_build EXIT
python3 - "$webrtc_src/BUILD.gn" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = '      "//:default",\n      "//:webrtc_lib_link_test",\n'
replacement = needle + '      "//dinox_wrapper:*",\n'
if text.count(needle) != 1:
    raise SystemExit("FAIL: pinned WebRTC visibility block was not found exactly once")
path.write_text(text.replace(needle, replacement), encoding="utf-8")
PY

gn_args="$(cat <<'GN'
target_os = "win"
target_cpu = "x64"
is_debug = false
is_component_build = false
rtc_include_tests = false
rtc_build_examples = false
treat_warnings_as_errors = false
use_rtti = true
use_custom_libcxx = false
symbol_level = 0
use_siso = true
use_remoteexec = false
rtc_use_h264 = true
proprietary_codecs = true
ffmpeg_branding = "Chrome"
rtc_use_h265 = false
GN
)"
info "Generating Windows GN output"
(cd "$webrtc_src" && "$GN_BIN" gen "$build_out" \
    --root-target=//dinox_wrapper:dinox-runtime --args="$gn_args")

ninja_args=(-C "$build_out")
if [[ -n "$jobs" ]]; then ninja_args+=("-local_jobs=$jobs"); fi
info "Building native Windows wrapper, worker and smoke test"
"$siso" ninja "${ninja_args[@]}" dinox-runtime

dll="$build_out/dinox-google-webrtc.dll"
worker="$build_out/dinox-webrtc-worker.exe"
smoke="$build_out/dinox-webrtc-process-engine-smoke.exe"
ipc_smoke="$build_out/dinox-webrtc-ipc-protocol-smoke.exe"
video_ring_smoke="$build_out/dinox-webrtc-video-ring-smoke.exe"
video_effects_smoke="$build_out/dinox-webrtc-video-effects-smoke.exe"
video_pipeline_effects_smoke="$build_out/dinox-webrtc-video-pipeline-effects-smoke.exe"
video_pipeline_privacy_smoke="$build_out/dinox-webrtc-video-pipeline-privacy-smoke.exe"
video_background_api_smoke="$build_out/dinox-webrtc-video-background-api-smoke.exe"
video_vision_geometry_golden="$build_out/dinox-webrtc-video-vision-geometry-golden.exe"
vision_fake_worker="$build_out/dinox-webrtc-vision-fake-worker.exe"
video_effects_baseline="$build_out/dinox-webrtc-video-effects-baseline.exe"
muji_sdp_smoke="$build_out/dinox-webrtc-muji-sdp-smoke.exe"
hardware_smoke="$build_out/dinox-webrtc-windows-codec-provider-smoke.exe"
codec_smoke="$build_out/dinox-webrtc-video-codec-smoke.exe"
import_lib="$build_out/dinox-google-webrtc.dll.lib"
for output in "$dll" "$worker" "$smoke" "$ipc_smoke" "$video_ring_smoke" "$muji_sdp_smoke" "$hardware_smoke" "$codec_smoke" \
    "$video_effects_smoke" "$video_pipeline_effects_smoke" "$video_pipeline_privacy_smoke" \
    "$video_background_api_smoke" "$video_vision_geometry_golden" "$vision_fake_worker" \
    "$video_effects_baseline" "$import_lib"; do
    [[ -s "$output" ]] || fail "expected Windows output missing: $output"
done

if [[ -e "$runtime_root" ]]; then
    [[ "$force" == true ]] || fail "runtime root exists; use --force: $runtime_root"
    rm -rf "$runtime_root"
fi
mkdir -p "$runtime_root/bin" "$runtime_root/lib" "$runtime_root/include"
cp "$dll" "$worker" "$smoke" "$ipc_smoke" "$video_ring_smoke" "$muji_sdp_smoke" "$hardware_smoke" "$codec_smoke" \
    "$video_effects_smoke" "$video_pipeline_effects_smoke" "$video_pipeline_privacy_smoke" \
    "$video_background_api_smoke" "$video_vision_geometry_golden" "$vision_fake_worker" \
    "$video_effects_baseline" "$runtime_root/bin/"
python3 "$PROJECT_ROOT/scripts/check-vision-runtime.py" --base "$vision_runtime" --platform windows
cp "$vision_runtime/dinox-vision-worker.exe" \
    "$vision_runtime/dinox-vision-runtime-manifest.json" \
    "$vision_runtime/dinox-vision-SHA256SUMS" "$runtime_root/bin/"
cp -R "$vision_runtime/dinox-vision-models" "$vision_runtime/dinox-vision-licenses" "$runtime_root/bin/"
python3 "$PROJECT_ROOT/scripts/check-vision-runtime.py" --base "$runtime_root/bin" --platform windows
cp "$PROJECT_ROOT/google-webrtc/include/dinox_webrtc.h" "$runtime_root/include/"
cp "$webrtc_src/LICENSE" "$runtime_root/LICENSE"
cp "$webrtc_src/PATENTS" "$runtime_root/PATENTS"
python3 "$PROJECT_ROOT/scripts/libwebrtc-codec-metadata.py" stage \
    "$webrtc_src" "$build_out" "$codec_sources" "$runtime_root"
cp "$ffmpeg_root/bin/avcodec-dinox-hw-62.dll" "$ffmpeg_root/bin/avutil-dinox-hw-60.dll" "$runtime_root/bin/"
cp "$ffmpeg_root/manifest.json" "$runtime_root/FFMPEG-WINDOWS-HARDWARE.json"
cp "$ffmpeg_root/FFMPEG-LICENSE" "$runtime_root/FFMPEG-LICENSE"
mkdir -p "$runtime_root/sources"
cp "$ffmpeg_root/sources/ffmpeg-8.1.2.tar.xz" "$ffmpeg_root/sources/ffmpeg-mf-dynamic-bitrate.patch" "$runtime_root/sources/"
info "Generating third-party licenses for the Windows runtime"
python3 "$PROJECT_ROOT/scripts/generate-libwebrtc-licenses.py" \
    --source "$webrtc_src" \
    --root-target '//dinox_wrapper:dinox-runtime' \
    --target '//dinox_wrapper:dinox-runtime' \
    "$runtime_root" \
    "$build_out"
[[ -s "$runtime_root/LICENSE.md" ]] \
    || fail "WebRTC license generator did not create a non-empty LICENSE.md"

"$llvm_bin/llvm-readobj" --coff-exports "$dll" \
    | awk '/^  Name: / { print $2 }' \
    | sort -u > "$runtime_root/lib/dinox-google-webrtc.def"
grep -q '^dinox_webrtc_' "$runtime_root/lib/dinox-google-webrtc.def" \
    || fail "could not extract DinoX C ABI exports from wrapper DLL"
{
    echo 'LIBRARY dinox-google-webrtc.dll'
    echo 'EXPORTS'
    sed 's/^/  /' "$runtime_root/lib/dinox-google-webrtc.def"
} > "$runtime_root/lib/dinox-google-webrtc.exports.def"
"$dlltool" -m i386:x86-64 \
    -d "$runtime_root/lib/dinox-google-webrtc.exports.def" \
    -D dinox-google-webrtc.dll \
    -l "$runtime_root/lib/libdinox-google-webrtc.dll.a"
rm "$runtime_root/lib/dinox-google-webrtc.def" "$runtime_root/lib/dinox-google-webrtc.exports.def"

final_dinox_source_commit="$(python3 "$PROVENANCE_CHECK" source-commit "$PROJECT_ROOT")"
[[ "$final_dinox_source_commit" == "$dinox_source_commit" ]] \
    || fail "DinoX source commit changed while building the Windows runtime"

python3 - "$runtime_root/manifest.json" "$PIN_COMMIT" "$dinox_source_commit" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
codecs = json.loads((path.parent / "WEBRTC-CODECS.json").read_text(encoding="utf-8"))
path.write_text(json.dumps({
    "artifact_abi": "dinox-libwebrtc-runtime-v2",
    "dinox_source_commit": sys.argv[3],
    "dinox_source_dirty": False,
    "ipc_protocol_version": 10,
    "layout": "dinox-libwebrtc-windows-runtime-v2",
    "source_commit": sys.argv[2],
    "target_cpu": "x64",
    "target_os": "win",
    "webrtc_branch": "7977",
    "webrtc_commit": sys.argv[2],
    "webrtc_milestone": 152,
    "video_ring_version": 6,
    "video_codecs": codecs,
    "windows_hardware_codecs": json.loads((path.parent / "FFMPEG-WINDOWS-HARDWARE.json").read_text()),
    "wrapper_abi": 40,
    "vision_runtime": {
        "manifest": "bin/dinox-vision-runtime-manifest.json",
        "payload_id": json.loads((path.parent / "bin/dinox-vision-runtime-manifest.json").read_text())["payload_id"],
    },
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

DINOX_LIBWEBRTC_DINOX_SOURCE_COMMIT="$dinox_source_commit" DINOX_LIBWEBRTC_MILESTONE=152 \
    "$PROJECT_ROOT/scripts/check-libwebrtc-windows-runtime.sh" \
    "$runtime_root" 40 10 6
# Keep the extracted runtime directory stable, but publish every runtime
# generation under a content-addressed name so older source tags remain
# reproducible when vendor-deps receives a newer ABI.
staged_archive="$(dirname "$runtime_root")/libwebrtc-m152-windows-x86_64-runtime.zip"
rm -f "$staged_archive" "$staged_archive.sha256"
find "$runtime_root" -exec touch -d 'UTC 2026-01-01 00:00:00' {} +
(cd "$(dirname "$runtime_root")" && \
    find "$(basename "$runtime_root")" -print | LC_ALL=C sort | TZ=UTC zip -q -X "$staged_archive" -@)
digest="$(sha256sum "$staged_archive" | awk '{print $1}')"
archive="$(dirname "$runtime_root")/libwebrtc-m152-windows-x86_64-runtime-abi40-ipc10-sha256-${digest:0:12}.zip"
mv -f "$staged_archive" "$archive"
(cd "$(dirname "$archive")" && \
    sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256" && \
    sha256sum -c "$(basename "$archive").sha256")
info "Prepared $archive"
info "Prepared $archive.sha256"
