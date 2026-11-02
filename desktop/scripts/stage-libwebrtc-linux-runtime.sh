#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVENANCE_CHECK="$PROJECT_ROOT/scripts/libwebrtc-runtime-provenance.py"
BUILD_DIR=""
RUNTIME_ROOT=""
VISION_RUNTIME=""
FORCE=false

# BEGIN RELEASE ORACLE GUARD
check_release_oracle_configuration() {
    python3 - "$BUILD_DIR" <<'PYORACLE'
import json
import pathlib
import shlex
import subprocess
import sys

build = pathlib.Path(sys.argv[1])
macro = "DINOX_WEBRTC_ENABLE_IN_PROCESS_TEST_ORACLE"


def fail(message):
    raise ValueError(message)


def regular(path, limit):
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= limit:
        fail("missing or unbounded release compiler evidence: " + path.name)
    return path.read_text(encoding="utf-8")


def expanded(words, directory, seen=None, depth=0):
    if not isinstance(words, list) or len(words) > 8192 or any(not isinstance(word, str) for word in words):
        fail("invalid release compiler arguments")
    if depth > 8:
        fail("compiler response files exceed the release inspection depth")
    seen = set() if seen is None else seen
    result = []
    index = 0
    while index < len(words):
        word = words[index]
        index += 1
        if word.startswith("@"):
            path = directory / word[1:]
            if path.is_symlink():
                fail("release compiler response file is a symlink")
            path = path.resolve()
            if path in seen or len(seen) >= 64:
                fail("cyclic or unbounded release compiler response files")
            seen.add(path)
            result.extend(expanded(shlex.split(regular(path, 1024 * 1024)), directory, seen, depth + 1))
        elif word.startswith("-Wp,"):
            result.extend(expanded(word[4:].split(","), directory, seen, depth + 1))
        elif word.startswith(("-Xclang=", "-Xpreprocessor=")):
            result.extend(expanded([word.split("=", 1)[1]], directory, seen, depth + 1))
        elif word in ("-Xclang", "-Xpreprocessor"):
            if index == len(words):
                fail("release compiler has an incomplete forwarded argument")
            result.extend(expanded([words[index]], directory, seen, depth + 1))
            index += 1
        else:
            result.append(word)
        if len(result) > 8192:
            fail("expanded release compiler arguments exceed their bound")
    return result


def check_flags(words, directory, reject_forced_headers=False):
    words = expanded(words, directory)
    for index, word in enumerate(words):
        value = None
        if word in ("-D", "/D", "--define-macro"):
            if index + 1 == len(words):
                fail("release compiler has an incomplete macro definition")
            value = words[index + 1]
        elif word.startswith(("-D", "/D")):
            value = word[2:]
        elif word.startswith("--define-macro="):
            value = word.split("=", 1)[1]
        if value is not None and value.split("=", 1)[0].split("(", 1)[0] == macro:
            # worker_proxy.cpp uses #ifdef: even a definition of zero enables
            # the oracle. A release must leave this macro entirely undefined.
            fail("release compiler defines the in-process test oracle")
        if reject_forced_headers and (word.startswith(("-include", "-imacros", "--include=", "--imacros="))):
            fail("release wrapper has externally forced headers with unproven oracle definitions")


try:
    options = json.loads(subprocess.run(["meson", "introspect", str(build), "--buildoptions"],
        capture_output=True, text=True, check=True, timeout=30).stdout)
    oracle = [item.get("value") for item in options if item.get("name") == "google-libwebrtc-test-oracle"]
    if oracle != [False]:
        fail("release staging requires Meson google-libwebrtc-test-oracle=false")
    for item in options:
        if item.get("name") in ("cpp_args", "c_args"):
            check_flags(item["value"], build, reject_forced_headers=True)
    commands = json.loads(regular(build / "compile_commands.json", 16 * 1024 * 1024))
    if not isinstance(commands, list) or not 1 <= len(commands) <= 100000:
        fail("release staging has no bounded compiler command inventory")
    wrapper_commands = 0
    for item in commands:
        directory = pathlib.Path(item.get("directory", str(build)))
        if not directory.is_absolute():
            directory = build / directory
        words = item.get("arguments")
        if words is None:
            words = shlex.split(item["command"])
        wrapper = "libdinox-google-webrtc.so.p/" in item.get("output", "")
        check_flags(words, directory, reject_forced_headers=wrapper)
        if wrapper and pathlib.Path(item["file"]).name == "dinox_webrtc_worker_proxy.cpp":
            wrapper_commands += 1
    if wrapper_commands != 1:
        fail("release staging lacks the exact wrapper proxy compiler command")
except (ValueError, OSError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as error:
    print("FAIL: Linux runtime release oracle guard: " + str(error), file=sys.stderr)
    sys.exit(1)
print("OK: release wrapper configuration leaves the in-process test oracle disabled")
PYORACLE
}
# END RELEASE ORACLE GUARD

usage() {
    echo "Usage: $0 --build-dir DIR --runtime-root DIR --vision-runtime DIR [--force]"
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
        --runtime-root) RUNTIME_ROOT="${2:-}"; shift 2 ;;
        --vision-runtime) VISION_RUNTIME="${2:-}"; shift 2 ;;
        --force) FORCE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ -n "$BUILD_DIR" && -n "$RUNTIME_ROOT" && -n "$VISION_RUNTIME" ]] || { usage >&2; exit 2; }
command -v patchelf >/dev/null 2>&1 || { echo "FAIL: patchelf is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git is required" >&2; exit 1; }
command -v meson >/dev/null 2>&1 || { echo "FAIL: meson is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required" >&2; exit 1; }
[[ -f "$PROVENANCE_CHECK" ]] || { echo "FAIL: runtime provenance checker is missing" >&2; exit 1; }
VISION_RUNTIME="$(realpath "$VISION_RUNTIME")"
python3 "$PROJECT_ROOT/scripts/check-vision-runtime.py" --base "$VISION_RUNTIME" --platform linux
dinox_source_commit="$(python3 "$PROVENANCE_CHECK" source-commit "$PROJECT_ROOT")"
BUILD_DIR="$(realpath "$BUILD_DIR")"
RUNTIME_ROOT="$(realpath -m "$RUNTIME_ROOT")"
[[ "$VISION_RUNTIME" != "$RUNTIME_ROOT" && "$VISION_RUNTIME" != "$RUNTIME_ROOT/"* ]] \
    || { echo "FAIL: vision input must be outside the replaced runtime root" >&2; exit 1; }
check_release_oracle_configuration
python3 "$PROVENANCE_CHECK" check-build-stamp \
    "$BUILD_DIR" "$PROJECT_ROOT" "$dinox_source_commit"
meson compile -C "$BUILD_DIR" dinox-google-webrtc dinox-webrtc-worker
compiled_dinox_source_commit="$(python3 "$PROVENANCE_CHECK" source-commit "$PROJECT_ROOT")"
[[ "$compiled_dinox_source_commit" == "$dinox_source_commit" ]] \
    || { echo "FAIL: DinoX source commit changed while compiling the Linux runtime" >&2; exit 1; }
python3 "$PROVENANCE_CHECK" check-build-stamp \
    "$BUILD_DIR" "$PROJECT_ROOT" "$dinox_source_commit"
WRAPPER="$BUILD_DIR/google-webrtc/libdinox-google-webrtc.so"
WORKER="$BUILD_DIR/google-webrtc/dinox-webrtc-worker"
[[ -s "$WRAPPER" && -x "$WORKER" ]] || { echo "FAIL: build outputs missing" >&2; exit 1; }
if [[ -e "$RUNTIME_ROOT" ]]; then
    [[ "$FORCE" == true ]] || { echo "FAIL: runtime root exists; use --force" >&2; exit 1; }
    rm -rf "$RUNTIME_ROOT"
fi
mkdir -p "$RUNTIME_ROOT/lib" "$RUNTIME_ROOT/include" "$RUNTIME_ROOT/sources"
install -m 0755 "$WRAPPER" "$RUNTIME_ROOT/lib/"
install -m 0755 "$WORKER" "$RUNTIME_ROOT/lib/"
cp -a "$VISION_RUNTIME/dinox-vision-worker" \
    "$VISION_RUNTIME/dinox-vision-models" "$VISION_RUNTIME/dinox-vision-licenses" \
    "$VISION_RUNTIME/dinox-vision-runtime-manifest.json" "$VISION_RUNTIME/dinox-vision-SHA256SUMS" \
    "$RUNTIME_ROOT/lib/"
python3 "$PROJECT_ROOT/scripts/check-vision-runtime.py" --base "$RUNTIME_ROOT/lib" --platform linux
patchelf --set-rpath '$ORIGIN' "$RUNTIME_ROOT/lib/libdinox-google-webrtc.so"
cp "$PROJECT_ROOT/google-webrtc/include/dinox_webrtc.h" "$RUNTIME_ROOT/include/"
ARTIFACT_ROOT="$(meson introspect "$BUILD_DIR" --buildoptions | python3 -c 'import json,sys; print(next(x["value"] for x in json.load(sys.stdin) if x["name"] == "google-libwebrtc-artifact-root"))')"
cp "$ARTIFACT_ROOT/LICENSE" "$RUNTIME_ROOT/LICENSE"
cp "$ARTIFACT_ROOT/LICENSE.md" "$RUNTIME_ROOT/LICENSE.md"
cp "$ARTIFACT_ROOT/PATENTS" "$RUNTIME_ROOT/PATENTS"
python3 "$PROJECT_ROOT/scripts/libwebrtc-codec-metadata.py" check "$ARTIFACT_ROOT"
cp "$ARTIFACT_ROOT/WEBRTC-CODECS.json" "$ARTIFACT_ROOT/WEBRTC-GN-ARGS.gn" "$RUNTIME_ROOT/"
codec_source="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["codec_source"])' "$ARTIFACT_ROOT/WEBRTC-CODECS.json")"
install -m 0644 "$ARTIFACT_ROOT/$codec_source" "$RUNTIME_ROOT/$codec_source"
cp "$ARTIFACT_ROOT/FFMPEG-LICENSE" "$RUNTIME_ROOT/FFMPEG-LICENSE"
cp "$ARTIFACT_ROOT/LIBVA-LICENSE" "$RUNTIME_ROOT/LIBVA-LICENSE"
cp "$ARTIFACT_ROOT/FFMPEG-VP8-VAAPI.json" "$RUNTIME_ROOT/FFMPEG-VP8-VAAPI.json"
install -m 0644 "$ARTIFACT_ROOT/sources/ffmpeg-dinox-symbol-versions.patch" "$RUNTIME_ROOT/sources/"
cp "$ARTIFACT_ROOT/NVIDIA-CODEC-HEADERS-LICENSE" "$RUNTIME_ROOT/"
install -m 0644 "$ARTIFACT_ROOT/sources/nv-codec-headers-n8.1.24.15.tar.gz" "$RUNTIME_ROOT/sources/"
install -m 0755 "$ARTIFACT_ROOT/lib/libavcodec-dinox-hw.so.62" "$RUNTIME_ROOT/lib/libavcodec-dinox-hw.so.62"
install -m 0755 "$ARTIFACT_ROOT/lib/libavutil-dinox-hw.so.60" "$RUNTIME_ROOT/lib/libavutil-dinox-hw.so.60"
install -m 0644 "$ARTIFACT_ROOT/sources/ffmpeg-8.1.2.tar.xz" "$RUNTIME_ROOT/sources/ffmpeg-8.1.2.tar.xz"
install -m 0644 "$ARTIFACT_ROOT/sources/libva-2.20.0.tar.gz" "$RUNTIME_ROOT/sources/libva-2.20.0.tar.gz"
final_dinox_source_commit="$(python3 "$PROVENANCE_CHECK" source-commit "$PROJECT_ROOT")"
[[ "$final_dinox_source_commit" == "$dinox_source_commit" ]] \
    || { echo "FAIL: DinoX source commit changed while staging the Linux runtime" >&2; exit 1; }
python3 - "$RUNTIME_ROOT/manifest.json" "$ARTIFACT_ROOT/FFMPEG-VP8-VAAPI.json" "$dinox_source_commit" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
vp8_decoder = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
codecs = json.loads((path.parent / "WEBRTC-CODECS.json").read_text(encoding="utf-8"))
path.write_text(json.dumps({
    "artifact_abi": "dinox-libwebrtc-runtime-v2",
    "dinox_source_commit": sys.argv[3],
    "dinox_source_dirty": False,
    "ipc_protocol_version": 10,
    "layout": "dinox-libwebrtc-linux-runtime-v2",
    "target_cpu": "x64",
    "target_os": "linux",
    "webrtc_branch": "7977",
    "webrtc_commit": "6f37672d358475cd17544121a12494da454d85fb",
    "webrtc_milestone": 152,
    "video_ring_version": 6,
    "video_codecs": codecs,
    "vp8_hardware_decoder": vp8_decoder,
    "wrapper_abi": 40,
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
check_release_oracle_configuration
DINOX_LIBWEBRTC_DINOX_SOURCE_COMMIT="$dinox_source_commit" DINOX_LIBWEBRTC_MILESTONE=152 \
    "$PROJECT_ROOT/scripts/check-libwebrtc-linux-runtime.sh" \
    "$RUNTIME_ROOT" 40 10 6 --vision-runtime "$RUNTIME_ROOT/lib"
staged_tarball="${RUNTIME_ROOT}.tar.gz"
rm -f "$staged_tarball" "$staged_tarball.sha256"
tar --sort=name --mtime='UTC 2026-01-01' --owner=0 --group=0 --numeric-owner \
    -C "$(dirname "$RUNTIME_ROOT")" -czf "$staged_tarball" "$(basename "$RUNTIME_ROOT")"
digest="$(sha256sum "$staged_tarball" | awk '{print $1}')"
tarball="$(dirname "$RUNTIME_ROOT")/$(basename "$RUNTIME_ROOT")-abi40-ipc10-sha256-${digest:0:12}.tar.gz"
mv -f "$staged_tarball" "$tarball"
(cd "$(dirname "$tarball")" && \
    sha256sum "$(basename "$tarball")" > "$(basename "$tarball").sha256" && \
    sha256sum -c "$(basename "$tarball").sha256")
echo "Prepared $tarball"
