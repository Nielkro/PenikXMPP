#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE_SCRIPT="$PROJECT_ROOT/scripts/stage-libwebrtc-artifact.sh"
VP8_VAAPI_BUILD_SCRIPT="$PROJECT_ROOT/scripts/build-libwebrtc-vp8-vaapi-dependency.sh"

DEFAULT_MILESTONE="152"
DEFAULT_BRANCH="7977"
DEFAULT_COMMIT="6f37672d358475cd17544121a12494da454d85fb"
DEFAULT_TARGET_OS="linux"
DEFAULT_TARGET_CPU="x64"
DEFAULT_TARGET_LABEL="linux-x86_64"
DEFAULT_OUT_NAME="m152-linux-x64"
DEFAULT_NINJA_TARGETS=(
    webrtc
    obj/api/video_codecs/libbuiltin_video_encoder_factory.a
    obj/api/video_codecs/libbuiltin_video_decoder_factory.a
)

usage() {
    cat <<'USAGE'
Usage:
  scripts/build-libwebrtc-artifact.sh \
    --work-dir /path/to/dinox-libwebrtc-m152 \
    --artifact-root /path/to/libwebrtc-m152-linux-x86_64 \
    --codec-sources /path/to/published-webrtc-m152-codec-sources.tar.gz \
    [--vp8-vaapi-root /path/to/ffmpeg-vp8-vaapi] \
    [--depot-tools-dir /path/to/depot_tools] \
    [--jobs N] [--ninja-target TARGET]... [--force] [--dry-run]

  scripts/build-libwebrtc-artifact.sh --self-test

Builds a pinned Google/libwebrtc checkout outside the DinoX source tree, then
stages a compact DinoX artifact using scripts/stage-libwebrtc-artifact.sh.

This script is intentionally not part of normal DinoX CI. WebRTC fetch/build is
large and should run only in an explicit dependency-builder environment.

Environment overrides for intentional future pin updates:
  DINOX_LIBWEBRTC_MILESTONE
  DINOX_LIBWEBRTC_BRANCH
  DINOX_LIBWEBRTC_COMMIT
  DINOX_LIBWEBRTC_TARGET_OS
  DINOX_LIBWEBRTC_TARGET_CPU
  DINOX_LIBWEBRTC_TARGET_LABEL
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
    if [[ "$dry_run" == "true" ]]; then
        printf 'DRY-RUN:'
        quote_args "$@"
        printf '\n'
    else
        "$@"
    fi
}

run_in_dir() {
    local dir="$1"
    shift

    if [[ "$dry_run" == "true" ]]; then
        printf 'DRY-RUN: cd %q &&' "$dir"
        quote_args "$@"
        printf '\n'
    else
        (cd "$dir" && "$@")
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

gn_args() {
    local target_os="$1"
    local target_cpu="$2"

    cat <<EOF
target_os="${target_os}"
target_cpu="${target_cpu}"
is_debug=false
is_component_build=false
rtc_include_tests=false
rtc_build_examples=false
treat_warnings_as_errors=false
use_rtti=true
use_custom_libcxx=true
symbol_level=0
use_siso=true
use_remoteexec=false
rtc_use_h264=true
proprietary_codecs=true
ffmpeg_branding="Chrome"
rtc_use_h265=false
EOF
}

prepare_depot_tools() {
    if [[ -d "$depot_tools_dir/.git" ]]; then
        info "Using existing depot_tools at $depot_tools_dir"
        return 0
    fi

    [[ "$skip_fetch" == "false" ]] \
        || fail "depot_tools missing and --skip-fetch was requested: $depot_tools_dir"

    info "Cloning depot_tools into $depot_tools_dir"
    run_cmd mkdir -p "$(dirname "$depot_tools_dir")"
    run_cmd git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$depot_tools_dir"
}

prepare_webrtc_checkout() {
    if [[ -d "$webrtc_src/.git" ]]; then
        info "Using existing WebRTC checkout at $webrtc_src"
    else
        [[ "$skip_fetch" == "false" ]] \
            || fail "WebRTC checkout missing and --skip-fetch was requested: $webrtc_src"

        info "Fetching WebRTC checkout into $work_dir"
        run_in_dir "$work_dir" fetch --nohooks webrtc
    fi

    if [[ "$skip_fetch" == "false" ]]; then
        info "Fetching WebRTC branch-heads/$branch and checking out exact pin $commit"
        run_in_dir "$webrtc_src" git fetch origin "refs/branch-heads/${branch}:refs/remotes/origin/branch-heads/${branch}"
        run_in_dir "$webrtc_src" git checkout --detach "$commit"
    else
        info "Using the existing pinned WebRTC checkout without fetching or changing HEAD"
    fi

    if [[ "$dry_run" == "false" ]]; then
        local actual_commit
        actual_commit="$(git -C "$webrtc_src" rev-parse HEAD)"
        [[ "$actual_commit" == "$commit" ]] \
            || fail "WebRTC checkout is $actual_commit, expected $commit"
    fi

    if [[ "$skip_sync" == "false" ]]; then
        info "Running gclient sync"
        run_in_dir "$webrtc_src" gclient sync
    else
        info "Skipping gclient sync"
    fi
}

build_webrtc() {
    if [[ "$skip_build" == "true" ]]; then
        info "Skipping WebRTC build"
        return 0
    fi

    local args
    args="$(gn_args "$target_os" "$target_cpu")"

    info "Generating GN build directory $build_out"
    run_in_dir "$webrtc_src" gn gen "$build_out" "--args=${args}"

    local siso="$webrtc_src/third_party/siso/cipd/siso"
    [[ "$dry_run" == true || -x "$siso" ]] || fail "pinned Siso executable missing: $siso"
    local ninja_cmd=("$siso" ninja -C "$build_out")
    if [[ -n "$jobs" ]]; then
        ninja_cmd+=("-local_jobs=${jobs}")
    fi
    ninja_cmd+=("${ninja_targets[@]}")

    info "Building WebRTC target(s): ${ninja_targets[*]:-default}"
    run_cmd "${ninja_cmd[@]}"
}

prepare_vp8_vaapi_dependency() {
    if [[ "$target_os" != "linux" ]]; then
        return 0
    fi
    if [[ -s "$vp8_vaapi_root/manifest.json" || -s "$vp8_vaapi_root/FFMPEG-VP8-VAAPI.json" ]]; then
        local dependency_manifest=manifest.json
        [[ -s "$vp8_vaapi_root/manifest.json" ]] || dependency_manifest=FFMPEG-VP8-VAAPI.json
        python3 "$PROJECT_ROOT/scripts/check-libwebrtc-hardware-dependency.py" "$vp8_vaapi_root" \
            --manifest "$dependency_manifest" --platform linux
        info "Using existing private hardware codec dependency at $vp8_vaapi_root"
        return 0
    fi
    [[ "$skip_build" == false ]] \
        || fail "VP8/VA-API dependency is missing while --skip-build is active: $vp8_vaapi_root"

    local command=(
        "$VP8_VAAPI_BUILD_SCRIPT"
        --work-dir "$work_dir/ffmpeg-hardware-codecs-v3-build"
        --output-root "$vp8_vaapi_root"
    )
    if [[ -n "$jobs" ]]; then
        command+=(--jobs "$jobs")
    fi
    if [[ "$dry_run" == true ]]; then
        command+=(--dry-run)
    fi
    info "Preparing the private dynamic VP8/VA-API decoder dependency"
    "${command[@]}"
}

stage_artifact() {
    local stage_cmd=(
        "$STAGE_SCRIPT"
        --webrtc-src "$webrtc_src"
        --build-out "$build_out"
        --artifact-root "$artifact_root"
        --codec-sources "$codec_sources"
    )

    if [[ "$package_artifact" == "true" ]]; then
        stage_cmd+=(--package)
    fi
    if [[ "$force" == "true" ]]; then
        stage_cmd+=(--force)
    fi
    if [[ "$target_os" == "linux" ]]; then
        stage_cmd+=(--vp8-vaapi-root "$vp8_vaapi_root")
    fi

    info "Staging DinoX libwebrtc artifact"
    run_cmd "${stage_cmd[@]}"
}

run_self_test() {
    require_tool python3

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    local output
    output="$(
        "$0" \
            --work-dir "$tmp/work" \
            --depot-tools-dir "$tmp/depot_tools" \
            --artifact-root "$tmp/libwebrtc-m152-linux-x86_64" \
            --jobs 2 \
            --dry-run
    )"

    grep -q 'DRY-RUN:' <<< "$output" || fail "self-test did not exercise dry-run"
    grep -q 'fetch --nohooks webrtc' <<< "$output" || fail "self-test missing WebRTC fetch command"
    grep -q 'refs/branch-heads/7977' <<< "$output" || fail "self-test missing branch pin"
    grep -q 'gn gen' <<< "$output" || fail "self-test missing GN generation"
    grep -q 'use_custom_libcxx=true' <<< "$output" || fail "self-test missing custom libc++ GN arg"
    grep -q 'rtc_use_h264=true' <<< "$output" || fail "self-test missing H.264 enablement"
    grep -q 'proprietary_codecs=true' <<< "$output" || fail "self-test missing proprietary codec enablement"
    grep -q 'ninja -C' <<< "$output" || fail "self-test missing Ninja build"
    grep -q 'libbuiltin_video_encoder_factory.a' <<< "$output" || fail "self-test missing video encoder factory target"
    grep -q 'libbuiltin_video_decoder_factory.a' <<< "$output" || fail "self-test missing video decoder factory target"
    grep -q -- '--enable-hwaccel=vp8_vaapi' <<< "$output" || fail "self-test missing VP8/VA-API dependency build"
    grep -q -- '--vp8-vaapi-root' <<< "$output" || fail "self-test missing VP8/VA-API artifact staging"
    grep -q 'stage-libwebrtc-artifact.sh' <<< "$output" || fail "self-test missing staging step"

    if "$0" --unknown-option >/dev/null 2>&1; then
        fail "self-test accepted an unknown option"
    fi

    echo "Self-test OK"
}

milestone="${DINOX_LIBWEBRTC_MILESTONE:-$DEFAULT_MILESTONE}"
branch="${DINOX_LIBWEBRTC_BRANCH:-$DEFAULT_BRANCH}"
commit="${DINOX_LIBWEBRTC_COMMIT:-$DEFAULT_COMMIT}"
target_os="${DINOX_LIBWEBRTC_TARGET_OS:-$DEFAULT_TARGET_OS}"
target_cpu="${DINOX_LIBWEBRTC_TARGET_CPU:-$DEFAULT_TARGET_CPU}"
target_label="${DINOX_LIBWEBRTC_TARGET_LABEL:-$DEFAULT_TARGET_LABEL}"

work_dir=""
depot_tools_dir=""
webrtc_src=""
build_out=""
artifact_root=""
vp8_vaapi_root=""
codec_sources=""
jobs="${DINOX_BUILD_JOBS:-${DINOX_CI_JOBS:-}}"
ninja_targets=("${DEFAULT_NINJA_TARGETS[@]}")
custom_ninja_targets=false
if [[ -n "${DINOX_LIBWEBRTC_NINJA_TARGET:-}" ]]; then
    ninja_targets=("${DINOX_LIBWEBRTC_NINJA_TARGET}")
    custom_ninja_targets=true
fi
dry_run=false
force=false
package_artifact=true
skip_fetch=false
skip_sync=false
skip_build=false

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --work-dir)
            work_dir="${2:-}"
            shift 2
            ;;
        --depot-tools-dir)
            depot_tools_dir="${2:-}"
            shift 2
            ;;
        --webrtc-src)
            webrtc_src="${2:-}"
            shift 2
            ;;
        --build-out)
            build_out="${2:-}"
            shift 2
            ;;
        --artifact-root)
            artifact_root="${2:-}"
            shift 2
            ;;
        --vp8-vaapi-root)
            vp8_vaapi_root="${2:-}"
            shift 2
            ;;
        --codec-sources)
            codec_sources="${2:-}"
            shift 2
            ;;
        --jobs)
            jobs="${2:-}"
            shift 2
            ;;
        --ninja-target)
            if [[ "$custom_ninja_targets" == "false" ]]; then
                ninja_targets=()
                custom_ninja_targets=true
            fi
            ninja_targets+=("${2:-}")
            shift 2
            ;;
        --ninja-default)
            ninja_targets=()
            custom_ninja_targets=true
            shift
            ;;
        --no-package)
            package_artifact=false
            shift
            ;;
        --force)
            force=true
            shift
            ;;
        --skip-fetch)
            skip_fetch=true
            shift
            ;;
        --skip-sync)
            skip_sync=true
            shift
            ;;
        --skip-build)
            skip_build=true
            shift
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --self-test)
            run_self_test
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$work_dir" ]]; then
    usage >&2
    exit 2
fi

if [[ -n "$jobs" && ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
    fail "invalid job count: $jobs"
fi

require_tool python3
if [[ "$dry_run" == "false" ]]; then
    [[ -s "$codec_sources" ]] || fail "--codec-sources must name the published M152 codec source archive"
    codec_sources="$(abs_path "$codec_sources")"
    require_tool git
fi

work_dir="$(abs_path "$work_dir")"
if [[ -z "$depot_tools_dir" ]]; then
    depot_tools_dir="$work_dir/depot_tools"
fi
depot_tools_dir="$(abs_path "$depot_tools_dir")"

if [[ -z "$webrtc_src" ]]; then
    webrtc_src="$work_dir/src"
fi
webrtc_src="$(abs_path "$webrtc_src")"

if [[ -z "$build_out" ]]; then
    build_out="$webrtc_src/out/$DEFAULT_OUT_NAME"
fi
build_out="$(abs_path "$build_out")"

if [[ -z "$artifact_root" ]]; then
    artifact_root="$work_dir/libwebrtc-m${milestone}-${target_label}"
fi
artifact_root="$(abs_path "$artifact_root")"

if [[ -z "$vp8_vaapi_root" ]]; then
    vp8_vaapi_root="$work_dir/ffmpeg-hardware-codecs-8.1.2-v3"
fi
vp8_vaapi_root="$(abs_path "$vp8_vaapi_root")"

export PATH="$depot_tools_dir:$PATH"
export DEPOT_TOOLS_UPDATE=0
export DINOX_LIBWEBRTC_MILESTONE="$milestone"
export DINOX_LIBWEBRTC_BRANCH="$branch"
export DINOX_LIBWEBRTC_COMMIT="$commit"
export DINOX_LIBWEBRTC_TARGET_OS="$target_os"
export DINOX_LIBWEBRTC_TARGET_CPU="$target_cpu"
export DINOX_LIBWEBRTC_TARGET_LABEL="$target_label"

run_cmd mkdir -p "$work_dir"
prepare_depot_tools
if [[ "$dry_run" == "false" ]]; then
    require_tool fetch
    require_tool gclient
    require_tool gn
    if [[ "$target_os" == "linux" ]]; then
        require_tool pkg-config
    fi
fi
prepare_webrtc_checkout
build_webrtc
prepare_vp8_vaapi_dependency
stage_artifact

info "Done"
