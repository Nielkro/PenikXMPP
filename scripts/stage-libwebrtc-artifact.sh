#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_SCRIPT="$PROJECT_ROOT/scripts/check-libwebrtc-artifact.sh"

DEFAULT_MILESTONE="152"
DEFAULT_BRANCH="7977"
DEFAULT_COMMIT="6f37672d358475cd17544121a12494da454d85fb"
DEFAULT_TARGET_OS="linux"
DEFAULT_TARGET_CPU="x64"
DEFAULT_TARGET_LABEL="linux-x86_64"
DEFAULT_ARTIFACT_ABI="dinox-libwebrtc-proof-v1"

usage() {
    cat <<'USAGE'
Usage:
  scripts/stage-libwebrtc-artifact.sh \
    --webrtc-src /path/to/webrtc/src \
    --build-out /path/to/webrtc/src/out/dinox-linux-x64 \
    --artifact-root /path/to/libwebrtc-m152-linux-x86_64 \
    --vp8-vaapi-root /path/to/ffmpeg-vp8-vaapi \
    --codec-sources /path/to/webrtc-m152-codec-sources-6f37672d3584-sha256-2b17c14cc13b.tar.gz \
    [--libwebrtc-a /path/to/libwebrtc.a] \
    [--package] [--force]

  scripts/stage-libwebrtc-artifact.sh --self-test

Stages a compact, pinned Google/libwebrtc artifact for DinoX proof builds.
The script does not fetch or build WebRTC. It consumes an already checked-out
and built WebRTC tree, validates the pinned commit, copies public headers,
generates LICENSE.md for //:webrtc, copies LICENSE/PATENTS and libwebrtc.a,
writes manifest.json, then runs
scripts/check-libwebrtc-artifact.sh.

Environment overrides for intentional future pin updates:
  DINOX_LIBWEBRTC_MILESTONE
  DINOX_LIBWEBRTC_BRANCH
  DINOX_LIBWEBRTC_COMMIT
  DINOX_LIBWEBRTC_ARTIFACT_ABI
USAGE
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

abs_path() {
    python3 - "$1" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).expanduser().resolve())
PY
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

generate_dependency_licenses() {
    local webrtc_src="$1"
    local build_out="$2"
    local output_dir="$3"
    local generator="$webrtc_src/tools_webrtc/libs/generate_licenses.py"
    local depot_tools="$webrtc_src/third_party/depot_tools"

    [[ -x "$generator" ]] \
        || fail "WebRTC license generator is missing or not executable: $generator"

    info "Generating third-party licenses for WebRTC and the built-in video factories"
    if (( milestone >= 152 )); then
        env "PATH=$depot_tools:$PATH" python3 "$PROJECT_ROOT/scripts/generate-libwebrtc-licenses.py" \
            --source "$webrtc_src" \
            --target '//:webrtc' \
            --target '//api/video_codecs:builtin_video_encoder_factory' \
            --target '//api/video_codecs:builtin_video_decoder_factory' \
            "$output_dir" "$build_out"
    else
        env "PATH=$depot_tools:$PATH" "$generator" \
            --target '//:webrtc' "$output_dir" "$build_out"
    fi
    [[ -s "$output_dir/LICENSE.md" ]] \
        || fail "WebRTC license generator did not create a non-empty LICENSE.md"
}

copy_headers_from_dir() {
    local src_dir="$1"
    local dest_dir="$2"

    [[ -d "$src_dir" ]] || return 0

    while IFS= read -r -d '' header; do
        local rel="${header#"$src_dir"/}"
        install -D -m 0644 "$header" "$dest_dir/$rel"
    done < <(find "$src_dir" -type f \( -name '*.h' -o -name '*.hpp' -o -name '*.hh' -o -name '*.inc' \) -print0)
}

copy_files_from_dir() {
    local src_dir="$1"
    local dest_dir="$2"

    [[ -d "$src_dir" ]] || return 0

    while IFS= read -r -d '' file_path; do
        local rel="${file_path#"$src_dir"/}"
        install -D -m 0644 "$file_path" "$dest_dir/$rel"
    done < <(find "$src_dir" -type f -print0)
}

find_libwebrtc_archive() {
    local build_out="$1"
    local explicit="${2:-}"

    if [[ -n "$explicit" ]]; then
        [[ -f "$explicit" ]] || fail "explicit libwebrtc archive not found: $explicit"
        abs_path "$explicit"
        return 0
    fi

    local candidates=(
        "$build_out/obj/libwebrtc.a"
        "$build_out/libwebrtc.a"
        "$build_out/obj/webrtc/libwebrtc.a"
    )

    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            abs_path "$candidate"
            return 0
        fi
    done

    fail "libwebrtc.a not found under $build_out; pass --libwebrtc-a explicitly after the WebRTC build"
}

create_static_archive_from_build_objects() {
    local output_archive="$1"
    local build_out="$2"
    shift 2

    local objects=()
    local object_rel
    for object_rel in "$@"; do
        local object_path="$build_out/$object_rel"
        [[ -f "$object_path" ]] || fail "required WebRTC object missing: $object_path"
        objects+=("$object_path")
    done

    rm -f "$output_archive"
    ar crsD "$output_archive" "${objects[@]}"
}

create_static_archive_from_archive_members() {
    local output_archive="$1"
    local build_out="$2"
    local input_archive="$3"
    local input_archive_dir
    input_archive_dir="$(dirname "$input_archive")"

    [[ -f "$input_archive" ]] || fail "input archive missing: $input_archive"

    local members=()
    mapfile -t members < <(ar t "$input_archive")
    [[ "${#members[@]}" -gt 0 ]] || fail "input archive has no members: $input_archive"

    local objects=()
    local member
    for member in "${members[@]}"; do
        local object_path=""
        if [[ "$member" = /* && -f "$member" ]]; then
            object_path="$member"
        elif [[ -f "$build_out/$member" ]]; then
            object_path="$build_out/$member"
        elif [[ -f "$input_archive_dir/$member" ]]; then
            object_path="$input_archive_dir/$member"
        fi
        [[ -n "$object_path" ]] || fail "archive member not found for $input_archive: $member"
        objects+=("$object_path")
    done

    rm -f "$output_archive"
    ar crsD "$output_archive" "${objects[@]}"
}

stage_chromium_libcxx_runtime() {
    local webrtc_src="$1"
    local build_out="$2"
    local artifact_root="$3"

    local libcxx_config_dir="$webrtc_src/buildtools/third_party/libc++"
    local libcxx_config="$libcxx_config_dir/__config_site"
    local libcxx_include="$webrtc_src/third_party/libc++/src/include"
    local libcxxabi_include="$webrtc_src/third_party/libc++abi/src/include"
    local libcxx_archive="$build_out/obj/buildtools/third_party/libc++/libc++.a"
    local libcxxabi_archive="$build_out/obj/buildtools/third_party/libc++abi/libc++abi.a"

    [[ -f "$libcxx_config" ]] || fail "Chromium libc++ __config_site missing: $libcxx_config"
    [[ -d "$libcxx_include" ]] || fail "Chromium libc++ headers missing: $libcxx_include"
    [[ -d "$libcxxabi_include" ]] || fail "Chromium libc++abi headers missing: $libcxxabi_include"
    [[ -f "$libcxx_archive" ]] || fail "Chromium libc++ archive missing: $libcxx_archive"
    [[ -f "$libcxxabi_archive" ]] || fail "Chromium libc++abi archive missing: $libcxxabi_archive"

    install -D -m 0644 "$libcxx_config" "$artifact_root/toolchain/libcxx-config/__config_site"
    copy_files_from_dir "$libcxx_config_dir" "$artifact_root/toolchain/libcxx-config"
    copy_files_from_dir "$libcxx_include" "$artifact_root/toolchain/libcxx/include"
    copy_files_from_dir "$libcxxabi_include" "$artifact_root/toolchain/libcxxabi/include"
    create_static_archive_from_archive_members "$artifact_root/lib/libc++.a" "$build_out" "$libcxx_archive"
    create_static_archive_from_archive_members "$artifact_root/lib/libc++abi.a" "$build_out" "$libcxxabi_archive"
}

stage_vp8_vaapi_dependency() {
    local dependency_root="$1"
    local artifact_root="$2"

    [[ -d "$dependency_root" ]] || fail "VP8/VA-API dependency root is missing: $dependency_root"
    local manifest_name=manifest.json
    local license_name=LICENSE
    local include_dir=include
    if [[ -s "$dependency_root/FFMPEG-VP8-VAAPI.json" ]]; then
        # Reuse the unchanged private decoder from a previously staged artifact.
        manifest_name=FFMPEG-VP8-VAAPI.json
        license_name=FFMPEG-LICENSE
        include_dir=include/ffmpeg-vp8-vaapi
    fi
    local avcodec=libavcodec
    local avutil=libavutil
    if (( milestone >= 152 )); then
        avcodec=libavcodec-dinox-hw
        avutil=libavutil-dinox-hw
    fi
    local required=(
        "$manifest_name"
        "$license_name"
        LIBVA-LICENSE
        "$include_dir/libavcodec/avcodec.h"
        "$include_dir/libavutil/hwcontext.h"
        "$include_dir/libavutil/hwcontext_vaapi.h"
        "$include_dir/va/va.h"
        "lib/$avcodec.so"
        "lib/$avcodec.so.62"
        "lib/$avutil.so"
        "lib/$avutil.so.60"
        sources/ffmpeg-8.1.2.tar.xz
        sources/libva-2.20.0.tar.gz
    )
    local relative
    for relative in "${required[@]}"; do
        [[ -s "$dependency_root/$relative" ]] \
            || fail "VP8/VA-API dependency is missing $relative"
    done

    if (( milestone >= 152 )); then
        python3 "$PROJECT_ROOT/scripts/check-libwebrtc-hardware-dependency.py" \
            "$dependency_root" --manifest "$manifest_name" --platform linux
    else
    python3 - "$dependency_root/$manifest_name" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
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
for key, value in expected.items():
    if data.get(key) != value:
        raise SystemExit(
            f"FAIL: VP8/VA-API manifest {key} is {data.get(key)!r}, expected {value!r}")
PY
    fi

    mkdir -p "$artifact_root/include/ffmpeg-vp8-vaapi"
    copy_headers_from_dir \
        "$dependency_root/$include_dir" \
        "$artifact_root/include/ffmpeg-vp8-vaapi"
    while IFS= read -r -d '' library; do
        cp -a "$library" "$artifact_root/lib/"
    done < <(find "$dependency_root/lib" -maxdepth 1 \
        \( -name "$avcodec.so*" -o -name "$avutil.so*" \) \
        \( -type f -o -type l \) -print0)
    mkdir -p "$artifact_root/sources"
    install -m 0644 \
        "$dependency_root/sources/ffmpeg-8.1.2.tar.xz" \
        "$artifact_root/sources/ffmpeg-8.1.2.tar.xz"
    install -m 0644 \
        "$dependency_root/sources/libva-2.20.0.tar.gz" \
        "$artifact_root/sources/libva-2.20.0.tar.gz"
    install -m 0644 "$dependency_root/$license_name" "$artifact_root/FFMPEG-LICENSE"
    install -m 0644 "$dependency_root/LIBVA-LICENSE" "$artifact_root/LIBVA-LICENSE"
    install -m 0644 \
        "$dependency_root/$manifest_name" \
        "$artifact_root/FFMPEG-VP8-VAAPI.json"
    if (( milestone >= 152 )); then
        install -m 0644 "$dependency_root/sources/ffmpeg-dinox-symbol-versions.patch" "$artifact_root/sources/"
        install -m 0644 "$dependency_root/NVIDIA-CODEC-HEADERS-LICENSE" "$artifact_root/"
        install -m 0644 "$dependency_root/sources/nv-codec-headers-n8.1.24.15.tar.gz" "$artifact_root/sources/"
    fi
}

stage_artifact() {
    local webrtc_src="$1"
    local build_out="$2"
    local artifact_root="$3"
    local explicit_archive="$4"
    local package_artifact="$5"
    local force="$6"
    local milestone="$7"
    local branch="$8"
    local expected_commit="$9"
    local target_os="${10}"
    local target_cpu="${11}"
    local target_label="${12}"
    local artifact_abi="${13}"
    local vp8_vaapi_root="${14}"
    local codec_sources="${15:-}"

    require_tool git
    require_tool python3
    require_tool install
    require_tool find
    require_tool ar
    require_tool sha256sum
    if [[ "$package_artifact" == "true" ]]; then
        require_tool tar
    fi

    webrtc_src="$(abs_path "$webrtc_src")"
    build_out="$(abs_path "$build_out")"
    artifact_root="$(abs_path "$artifact_root")"

    [[ -d "$webrtc_src/.git" ]] || fail "not a WebRTC git checkout: $webrtc_src"
    [[ -d "$build_out" ]] || fail "build output directory not found: $build_out"
    [[ -f "$webrtc_src/LICENSE" ]] || fail "WebRTC LICENSE not found in $webrtc_src"
    [[ -f "$webrtc_src/PATENTS" ]] || fail "WebRTC PATENTS not found in $webrtc_src"

    local actual_commit
    actual_commit="$(git -C "$webrtc_src" rev-parse HEAD)"
    [[ "$actual_commit" == "$expected_commit" ]] \
        || fail "WebRTC checkout is $actual_commit, expected $expected_commit"

    local archive
    archive="$(find_libwebrtc_archive "$build_out" "$explicit_archive")"

    if [[ -e "$artifact_root" ]]; then
        if [[ "$force" == "true" ]]; then
            rm -rf "$artifact_root"
        else
            fail "artifact root already exists; use --force to replace it: $artifact_root"
        fi
    fi

    info "Staging Google/libwebrtc M${milestone} ${target_label} artifact"
    mkdir -p "$artifact_root/include" "$artifact_root/lib"

    cp "$webrtc_src/LICENSE" "$artifact_root/LICENSE"
    cp "$webrtc_src/PATENTS" "$artifact_root/PATENTS"
    if (( milestone >= 152 )); then
        python3 "$PROJECT_ROOT/scripts/libwebrtc-codec-metadata.py" stage \
            "$webrtc_src" "$build_out" "$codec_sources" "$artifact_root"
    fi
    generate_dependency_licenses "$webrtc_src" "$build_out" "$artifact_root"
    if [[ -f "$webrtc_src/README.chromium" ]]; then
        cp "$webrtc_src/README.chromium" "$artifact_root/README.chromium"
    fi
    cp "$archive" "$artifact_root/lib/libwebrtc.a"
    create_static_archive_from_build_objects \
        "$artifact_root/lib/libwebrtc-dinox-video.a" \
        "$build_out" \
        obj/api/video_codecs/builtin_video_encoder_factory/builtin_video_encoder_factory.o \
        obj/api/video_codecs/builtin_video_decoder_factory/builtin_video_decoder_factory.o \
        obj/api/video_codecs/rtc_software_fallback_wrappers/video_decoder_software_fallback_wrapper.o \
        obj/api/video_codecs/rtc_software_fallback_wrappers/video_encoder_software_fallback_wrapper.o \
        obj/media/rtc_internal_video_codecs/fake_video_codec_factory.o \
        obj/media/rtc_internal_video_codecs/internal_decoder_factory.o \
        obj/media/rtc_internal_video_codecs/internal_encoder_factory.o \
        obj/media/rtc_simulcast_encoder_adapter/simulcast_encoder_adapter.o
    stage_chromium_libcxx_runtime "$webrtc_src" "$build_out" "$artifact_root"
    if [[ "$target_os" == "linux" ]]; then
        vp8_vaapi_root="$(abs_path "$vp8_vaapi_root")"
        stage_vp8_vaapi_dependency "$vp8_vaapi_root" "$artifact_root"
    fi

    local public_dirs=(
        api
        call
        common_audio
        common_video
        logging
        media
        modules
        p2p
        pc
        rtc_base
        system_wrappers
    )

    local dir
    for dir in "${public_dirs[@]}"; do
        copy_headers_from_dir "$webrtc_src/$dir" "$artifact_root/include/$dir"
    done

    copy_headers_from_dir "$webrtc_src/third_party/abseil-cpp/absl" "$artifact_root/include/absl"
    copy_headers_from_dir "$webrtc_src/third_party/libyuv/include/libyuv" "$artifact_root/include/libyuv"

    python3 - "$artifact_root/manifest.json" \
        "$milestone" "$branch" "$expected_commit" "$target_os" "$target_cpu" "$target_label" "$artifact_abi" "$actual_commit" \
        "$artifact_root/FFMPEG-VP8-VAAPI.json" <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
data = {
    "webrtc_milestone": int(sys.argv[2]),
    "webrtc_branch": sys.argv[3],
    "webrtc_commit": sys.argv[4],
    "target_os": sys.argv[5],
    "target_cpu": sys.argv[6],
    "target_label": sys.argv[7],
    "artifact_abi": sys.argv[8],
    "source_commit": sys.argv[9],
    "cxx_runtime": {
        "name": "chromium-libc++",
        "linkage": "static",
    },
    "layout": "dinox-libwebrtc-artifact-v1",
}
codec_manifest = manifest_path.parent / "WEBRTC-CODECS.json"
if codec_manifest.is_file():
    data["video_codecs"] = json.loads(codec_manifest.read_text(encoding="utf-8"))
ffmpeg_manifest = pathlib.Path(sys.argv[10])
if ffmpeg_manifest.is_file():
    data["vp8_hardware_decoder"] = json.loads(
        ffmpeg_manifest.read_text(encoding="utf-8"))
manifest_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

    DINOX_LIBWEBRTC_MILESTONE="$milestone" \
    DINOX_LIBWEBRTC_BRANCH="$branch" \
    DINOX_LIBWEBRTC_COMMIT="$expected_commit" \
    DINOX_LIBWEBRTC_ARTIFACT_ABI="$artifact_abi" \
        "$CHECK_SCRIPT" "$artifact_root"

    if [[ "$package_artifact" == "true" ]]; then
        local parent
        local base
        local tarball
        parent="$(dirname "$artifact_root")"
        base="$(basename "$artifact_root")"
        tarball="${artifact_root}.tar.gz"
        rm -f "$tarball" "${tarball}.sha256"
        tar --sort=name --mtime='UTC 2026-01-01' --owner=0 --group=0 --numeric-owner \
            -C "$parent" -czf "$tarball" "$base"
        sha256sum "$tarball" > "${tarball}.sha256"
        sha256sum -c "${tarball}.sha256"
        info "Prepared $tarball"
        info "Prepared ${tarball}.sha256"
    fi
}

run_self_test() {
    require_tool git
    require_tool python3
    require_tool ar
    require_tool sha256sum
    require_tool tar

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    local src="$tmp/webrtc-src"
    local out="$src/out/dinox-test"
    mkdir -p \
        "$src/api" \
        "$src/buildtools/third_party/libc++" \
        "$src/logging/rtc_event_log/events" \
        "$src/rtc_base" \
        "$src/third_party/abseil-cpp/absl" \
        "$src/third_party/libc++/src/include" \
        "$src/third_party/libc++abi/src/include" \
        "$src/tools_webrtc/libs" \
        "$tmp/vp8-vaapi/include/libavcodec" \
        "$tmp/vp8-vaapi/include/libavutil" \
        "$tmp/vp8-vaapi/include/va" \
        "$tmp/vp8-vaapi/lib" \
        "$tmp/vp8-vaapi/sources" \
        "$out/obj/api/video_codecs/builtin_video_decoder_factory" \
        "$out/obj/api/video_codecs/builtin_video_encoder_factory" \
        "$out/obj/api/video_codecs/rtc_software_fallback_wrappers" \
        "$out/obj/buildtools/third_party/libc++" \
        "$out/obj/buildtools/third_party/libc++/libc++" \
        "$out/obj/buildtools/third_party/libc++abi" \
        "$out/obj/buildtools/third_party/libc++abi/libc++abi" \
        "$out/obj/media/rtc_internal_video_codecs" \
        "$out/obj/media/rtc_simulcast_encoder_adapter"
    printf '%s\n' 'test license' > "$src/LICENSE"
    printf '%s\n' 'test patents' > "$src/PATENTS"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        '[[ "$#" -eq 4 ]]' \
        '[[ "$1" == "--target" ]]' \
        '[[ "$2" == "//:webrtc" ]]' \
        '[[ -d "$3" ]]' \
        '[[ -d "$4" ]]' \
        'printf "# webrtc\\ntest license\\n\\n# abseil-cpp\\ntest dependency license\\n" > "$3/LICENSE.md"' \
        > "$src/tools_webrtc/libs/generate_licenses.py"
    chmod +x "$src/tools_webrtc/libs/generate_licenses.py"
    printf '%s\n' '#pragma once' > "$src/api/create_peerconnection_factory.h"
    printf '%s\n' '#pragma once' > "$src/api/peer_connection_interface.h"
    printf '%s\n' '#pragma once' > "$src/logging/rtc_event_log/events/rtc_event_ice_candidate_pair.h"
    printf '%s\n' '#pragma once' > "$src/rtc_base/ref_count.h"
    printf '%s\n' '#pragma once' > "$src/third_party/abseil-cpp/absl/base.h"
    printf '%s\n' '#pragma once' > "$src/buildtools/third_party/libc++/__assertion_handler"
    printf '%s\n' '#define _LIBCPP_ABI_NAMESPACE __Cr' > "$src/buildtools/third_party/libc++/__config_site"
    printf '%s\n' '#pragma once' > "$src/third_party/libc++/src/include/vector"
    printf '%s\n' '#pragma once' > "$src/third_party/libc++abi/src/include/cxxabi.h"
    printf '%s\n' '#pragma once' > "$tmp/vp8-vaapi/include/libavcodec/avcodec.h"
    printf '%s\n' '#pragma once' > "$tmp/vp8-vaapi/include/libavutil/hwcontext.h"
    printf '%s\n' '#pragma once' > "$tmp/vp8-vaapi/include/libavutil/hwcontext_vaapi.h"
    printf '%s\n' '#pragma once' > "$tmp/vp8-vaapi/include/va/va.h"
    printf '%s\n' 'fake shared library' > "$tmp/vp8-vaapi/lib/libavcodec.so.62"
    ln -s libavcodec.so.62 "$tmp/vp8-vaapi/lib/libavcodec.so"
    printf '%s\n' 'fake shared library' > "$tmp/vp8-vaapi/lib/libavutil.so.60"
    ln -s libavutil.so.60 "$tmp/vp8-vaapi/lib/libavutil.so"
    printf '%s\n' 'fake ffmpeg source' > "$tmp/vp8-vaapi/sources/ffmpeg-8.1.2.tar.xz"
    printf '%s\n' 'fake libva source' > "$tmp/vp8-vaapi/sources/libva-2.20.0.tar.gz"
    printf '%s\n' 'test LGPL license' > "$tmp/vp8-vaapi/LICENSE"
    printf '%s\n' 'test MIT license' > "$tmp/vp8-vaapi/LIBVA-LICENSE"
    python3 - "$tmp/vp8-vaapi/manifest.json" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "codec": "VP8",
    "ffmpeg_version": "8.1.2",
    "hardware_api": "VA-API",
    "corresponding_source": "sources/ffmpeg-8.1.2.tar.xz",
    "layout": "dinox-ffmpeg-vp8-vaapi-v2",
    "libva_header_version": "2.20.0",
    "libva_source_sha256": "117f8d658a5fc9ea406ca80a3eb4ae1d70b15a54807c9ed77199c812bed73b60",
    "libva_source_url": "https://example.invalid/libva.tar.gz",
    "license": "LGPL-2.1-or-later",
    "libva_corresponding_source": "sources/libva-2.20.0.tar.gz",
    "linkage": "dynamic-private",
    "source_sha256": "464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c",
    "source_url": "https://example.invalid/ffmpeg.tar.xz",
    "configure": "test",
}) + "\n", encoding="utf-8")
PY
    printf '!<arch>\n' > "$out/obj/libwebrtc.a"
    printf '%s\n' 'fake object' > "$out/obj/buildtools/third_party/libc++/vector.o"
    printf '%s\n' 'fake object' > "$out/obj/buildtools/third_party/libc++abi/cxxabi.o"
    ar crs "$out/obj/buildtools/third_party/libc++/libc++.a" "$out/obj/buildtools/third_party/libc++/vector.o"
    ar crs "$out/obj/buildtools/third_party/libc++abi/libc++abi.a" "$out/obj/buildtools/third_party/libc++abi/cxxabi.o"
    printf '%s\n' 'fake object' > "$out/obj/api/video_codecs/builtin_video_decoder_factory/builtin_video_decoder_factory.o"
    printf '%s\n' 'fake object' > "$out/obj/api/video_codecs/builtin_video_encoder_factory/builtin_video_encoder_factory.o"
    printf '%s\n' 'fake object' > "$out/obj/api/video_codecs/rtc_software_fallback_wrappers/video_decoder_software_fallback_wrapper.o"
    printf '%s\n' 'fake object' > "$out/obj/api/video_codecs/rtc_software_fallback_wrappers/video_encoder_software_fallback_wrapper.o"
    printf '%s\n' 'fake object' > "$out/obj/media/rtc_internal_video_codecs/fake_video_codec_factory.o"
    printf '%s\n' 'fake object' > "$out/obj/media/rtc_internal_video_codecs/internal_decoder_factory.o"
    printf '%s\n' 'fake object' > "$out/obj/media/rtc_internal_video_codecs/internal_encoder_factory.o"
    printf '%s\n' 'fake object' > "$out/obj/media/rtc_simulcast_encoder_adapter/simulcast_encoder_adapter.o"

    git -C "$src" init -q
    git -C "$src" add .
    git -C "$src" -c user.name='DinoX Test' -c user.email='test@dinox.im' commit -q -m 'test fixture'
    local commit
    commit="$(git -C "$src" rev-parse HEAD)"

    stage_artifact \
        "$src" \
        "$out" \
        "$tmp/libwebrtc-m1-test" \
        "" \
        true \
        false \
        "1" \
        "test" \
        "$commit" \
        "linux" \
        "x64" \
        "test" \
        "dinox-libwebrtc-test-v1" \
        "$tmp/vp8-vaapi"

    [[ -f "$tmp/libwebrtc-m1-test.tar.gz" ]] || fail "self-test tarball missing"
    [[ -f "$tmp/libwebrtc-m1-test.tar.gz.sha256" ]] || fail "self-test checksum missing"
    tar -tzf \
        "$tmp/libwebrtc-m1-test.tar.gz" \
        'libwebrtc-m1-test/LICENSE.md' >/dev/null \
        || fail "self-test tarball is missing LICENSE.md"
    grep -Fx '# abseil-cpp' "$tmp/libwebrtc-m1-test/LICENSE.md" >/dev/null \
        || fail "self-test generated dependency LICENSE.md is missing"
    mv \
        "$tmp/libwebrtc-m1-test/LICENSE.md" \
        "$tmp/libwebrtc-m1-test/LICENSE.md.saved"
    if DINOX_LIBWEBRTC_MILESTONE=1 \
        DINOX_LIBWEBRTC_BRANCH=test \
        DINOX_LIBWEBRTC_COMMIT="$commit" \
        DINOX_LIBWEBRTC_ARTIFACT_ABI=dinox-libwebrtc-test-v1 \
        "$CHECK_SCRIPT" "$tmp/libwebrtc-m1-test" >/dev/null 2>&1; then
        fail "self-test checker accepted an artifact without LICENSE.md"
    fi
    mv \
        "$tmp/libwebrtc-m1-test/LICENSE.md.saved" \
        "$tmp/libwebrtc-m1-test/LICENSE.md"
    echo "Self-test OK"
}

webrtc_src=""
build_out=""
artifact_root=""
explicit_archive=""
vp8_vaapi_root=""
codec_sources=""
package_artifact=false
force=false
milestone="${DINOX_LIBWEBRTC_MILESTONE:-$DEFAULT_MILESTONE}"
branch="${DINOX_LIBWEBRTC_BRANCH:-$DEFAULT_BRANCH}"
commit="${DINOX_LIBWEBRTC_COMMIT:-$DEFAULT_COMMIT}"
target_os="${DINOX_LIBWEBRTC_TARGET_OS:-$DEFAULT_TARGET_OS}"
target_cpu="${DINOX_LIBWEBRTC_TARGET_CPU:-$DEFAULT_TARGET_CPU}"
target_label="${DINOX_LIBWEBRTC_TARGET_LABEL:-$DEFAULT_TARGET_LABEL}"
artifact_abi="${DINOX_LIBWEBRTC_ARTIFACT_ABI:-$DEFAULT_ARTIFACT_ABI}"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
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
        --libwebrtc-a)
            explicit_archive="${2:-}"
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
        --package)
            package_artifact=true
            shift
            ;;
        --force)
            force=true
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

if [[ -z "$webrtc_src" || -z "$build_out" ]]; then
    usage >&2
    exit 2
fi

if [[ "$target_os" == "linux" && -z "$vp8_vaapi_root" ]]; then
    fail "--vp8-vaapi-root is required for Linux artifacts"
fi
if (( milestone >= 152 )) && [[ ! -s "$codec_sources" ]]; then
    fail "--codec-sources must name the published M152 codec source archive"
fi

if [[ -z "$artifact_root" ]]; then
    artifact_root="$PWD/libwebrtc-m${milestone}-${target_label}"
fi

stage_artifact \
    "$webrtc_src" \
    "$build_out" \
    "$artifact_root" \
    "$explicit_archive" \
    "$package_artifact" \
    "$force" \
    "$milestone" \
    "$branch" \
    "$commit" \
    "$target_os" \
    "$target_cpu" \
    "$target_label" \
    "$artifact_abi" \
    "$vp8_vaapi_root" \
    "$codec_sources"
