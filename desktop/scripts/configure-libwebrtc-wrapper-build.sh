#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_SCRIPT="$PROJECT_ROOT/scripts/check-libwebrtc-artifact.sh"
PROVENANCE_CHECK="$PROJECT_ROOT/scripts/libwebrtc-runtime-provenance.py"
PROVENANCE_STAMP_NAME="dinox-libwebrtc-wrapper-provenance.json"

usage() {
    cat <<'USAGE'
Usage:
  scripts/configure-libwebrtc-wrapper-build.sh \
    --artifact-root /path/to/libwebrtc-m152-linux-x86_64 \
    --webrtc-src /path/to/webrtc/src \
    [--build-dir build-google-webrtc] [--wipe|--reconfigure] [--dry-run] [-- MESON_ARGS...]

  scripts/configure-libwebrtc-wrapper-build.sh \
    --artifact-root /path/to/libwebrtc-m152-linux-x86_64 \
    --clang /path/to/clang \
    --clangxx /path/to/clang++ \
    [--build-dir build-google-webrtc] [--wipe|--reconfigure] [--dry-run] [-- MESON_ARGS...]

  scripts/configure-libwebrtc-wrapper-build.sh --self-test

Configures a DinoX Meson build with the native Google/libwebrtc wrapper enabled.
The pinned WebRTC M152 artifact uses Chromium libc++ headers that require Clang
21 or newer. For reproducible proof builds, point this helper at the WebRTC
checkout that produced the artifact; it uses Chromium's bundled clang/clang++.
USAGE
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

detect_clang_major() {
    local compiler="$1"
    "$compiler" --version | sed -n '1s/.*clang version \([0-9][0-9]*\).*/\1/p'
}

quote_args() {
    local arg
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
}

abs_path() {
    python3 - "$1" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).expanduser().resolve())
PY
}

run_env_cmd() {
    local toolchain_bin="$1"
    local clang="$2"
    local clangxx_driver="$3"
    local ldflags="-fuse-ld=lld"
    shift 3

    if [[ -n "${LDFLAGS:-}" ]]; then
        ldflags="$ldflags $LDFLAGS"
    fi

    if [[ "$dry_run" == "true" ]]; then
        printf 'DRY-RUN:'
        quote_args env "PATH=$toolchain_bin:\$PATH" "CC=$clang" "CXX=$clangxx_driver" CC_LD=lld CXX_LD=lld "LDFLAGS=$ldflags" "$@"
        printf '\n'
    else
        env PATH="$toolchain_bin:$PATH" CC="$clang" CXX="$clangxx_driver" CC_LD=lld CXX_LD=lld LDFLAGS="$ldflags" "$@"
    fi
}

create_clangxx_driver() {
    local build_dir="$1"
    local clang="$2"
    local wrapper_dir="${build_dir}.toolchain"
    local wrapper="$wrapper_dir/clang++"

    if [[ "$dry_run" == "false" ]]; then
        mkdir -p "$wrapper_dir"
        local tmp_wrapper="$wrapper.tmp.$$"
        printf '#!/usr/bin/env bash\nexec %q --driver-mode=g++ "$@"\n' "$clang" > "$tmp_wrapper"
        chmod 0755 "$tmp_wrapper"
        mv -f "$tmp_wrapper" "$wrapper"
    fi

    printf '%s\n' "$wrapper"
}

run_check_cmd() {
    local clangxx="$1"
    local artifact_root="$2"

    if [[ "$dry_run" == "true" ]]; then
        printf 'DRY-RUN:'
        quote_args env DINOX_LIBWEBRTC_COMPILE_PROBE=1 "CXX=$clangxx" "$CHECK_SCRIPT" "$artifact_root"
        printf '\n'
    else
        env DINOX_LIBWEBRTC_COMPILE_PROBE=1 CXX="$clangxx" "$CHECK_SCRIPT" "$artifact_root"
    fi
}

run_self_test() {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    local output
    output="$(
        "$0" \
            --artifact-root "$tmp/libwebrtc-m152-linux-x86_64" \
            --webrtc-src "$tmp/webrtc/src" \
            --build-dir "$tmp/build-google-webrtc" \
            --wipe \
            --dry-run \
            -- -Dplugin-rtp=enabled
    )"

    grep -q 'DRY-RUN:' <<< "$output" || fail "self-test did not exercise dry-run"
    grep -q 'third_party/llvm-build/Release+Asserts/bin/clang++' <<< "$output" || fail "self-test missing Chromium clang++ path"
    grep -q 'check-libwebrtc-artifact.sh' <<< "$output" || fail "self-test missing artifact checker"
    grep -q 'DINOX_LIBWEBRTC_COMPILE_PROBE=1' <<< "$output" || fail "self-test missing compile probe"
    grep -q 'meson setup' <<< "$output" || fail "self-test missing Meson setup"
    local expected_setup
    expected_setup="$(quote_args meson setup "$tmp/build-google-webrtc" "$PROJECT_ROOT")"
    grep -Fq "$expected_setup" <<< "$output" || fail "self-test missing explicit DinoX source root"
    grep -q 'build-google-webrtc.toolchain/clang++' <<< "$output" || fail "self-test missing clang++ linker wrapper"
    grep -q 'google-libwebrtc-wrapper=enabled' <<< "$output" || fail "self-test missing wrapper option"
    grep -q 'plugin-rtp=enabled' <<< "$output" || fail "self-test missing forwarded Meson arg"
    grep -q 'CXX_LD=lld' <<< "$output" || fail "self-test missing C++ lld linker selection"
    grep -q 'LDFLAGS=-fuse-ld=lld' <<< "$output" || fail "self-test missing lld linker flag"
    grep -q "$PROVENANCE_STAMP_NAME" <<< "$output" || fail "self-test missing wrapper build provenance stamp"

    if "$0" --unknown-option >/dev/null 2>&1; then
        fail "self-test accepted an unknown option"
    fi

    echo "Self-test OK"
}

artifact_root=""
webrtc_src=""
clang=""
clangxx=""
build_dir="build-google-webrtc"
dry_run=false
wipe=false
reconfigure=false
meson_args=()

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --artifact-root)
            artifact_root="${2:-}"
            shift 2
            ;;
        --webrtc-src)
            webrtc_src="${2:-}"
            shift 2
            ;;
        --clang)
            clang="${2:-}"
            shift 2
            ;;
        --clangxx)
            clangxx="${2:-}"
            shift 2
            ;;
        --build-dir)
            build_dir="${2:-}"
            shift 2
            ;;
        --wipe)
            wipe=true
            shift
            ;;
        --reconfigure)
            reconfigure=true
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
        --)
            shift
            meson_args+=("$@")
            break
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$wipe" == "false" || "$reconfigure" == "false" ]] || fail "--wipe and --reconfigure are mutually exclusive"
[[ -n "$artifact_root" ]] || fail "--artifact-root is required"
[[ -n "$build_dir" ]] || fail "--build-dir must not be empty"
command -v git >/dev/null 2>&1 || fail "required tool not found: git"

if [[ -n "$webrtc_src" ]]; then
    webrtc_src="$(abs_path "$webrtc_src")"
    [[ -n "$clang" ]] || clang="$webrtc_src/third_party/llvm-build/Release+Asserts/bin/clang"
    [[ -n "$clangxx" ]] || clangxx="$webrtc_src/third_party/llvm-build/Release+Asserts/bin/clang++"
fi

[[ -n "$clang" && -n "$clangxx" ]] || fail "provide --webrtc-src or both --clang and --clangxx"

artifact_root="$(abs_path "$artifact_root")"
build_dir="$(abs_path "$build_dir")"
clang="$(abs_path "$clang")"
clangxx="$(abs_path "$clangxx")"
toolchain_bin="$(dirname "$clangxx")"

if [[ "$dry_run" == "false" ]]; then
    command -v meson >/dev/null 2>&1 || fail "required tool not found: meson"
    command -v python3 >/dev/null 2>&1 || fail "required tool not found: python3"
    [[ -x "$CHECK_SCRIPT" ]] || fail "artifact checker is not executable: $CHECK_SCRIPT"
    [[ -f "$PROVENANCE_CHECK" ]] || fail "runtime provenance checker is missing: $PROVENANCE_CHECK"
    [[ -d "$artifact_root" ]] || fail "artifact root is not a directory: $artifact_root"
    [[ -x "$clang" ]] || fail "clang is not executable: $clang"
    [[ -x "$clangxx" ]] || fail "clang++ is not executable: $clangxx"
    clangxx_major="$(detect_clang_major "$clangxx")"
    [[ -n "$clangxx_major" ]] || fail "could not determine clang++ major version from: $clangxx"
    [[ "$clangxx_major" -ge 21 ]] || fail "clang++ >= 21 is required for the pinned WebRTC M152 artifact; got $clangxx_major from $clangxx"
    if [[ ! -x "$toolchain_bin/ld.lld" ]] && ! command -v ld.lld >/dev/null 2>&1; then
        fail "ld.lld not found next to clang++ or in PATH"
    fi
fi

if [[ "$dry_run" == "true" ]]; then
    dinox_source_commit="$(git -C "$PROJECT_ROOT" rev-parse --verify 'HEAD^{commit}')"
else
    dinox_source_commit="$(python3 "$PROVENANCE_CHECK" source-commit "$PROJECT_ROOT")"
    rm -f "$build_dir/$PROVENANCE_STAMP_NAME"
fi

setup_args=(
    setup
    "$build_dir"
    "$PROJECT_ROOT"
    "-Dgoogle-libwebrtc-artifact-root=$artifact_root"
    -Dgoogle-libwebrtc-wrapper=enabled
)

if [[ "$wipe" == "true" ]]; then
    setup_args+=(--wipe)
elif [[ "$reconfigure" == "true" ]]; then
    setup_args+=(--reconfigure)
fi

setup_args+=("${meson_args[@]}")

info "Validating Google/libwebrtc artifact"
run_check_cmd "$clangxx" "$artifact_root"

info "Configuring wrapper-enabled Meson build"
clangxx_driver="$(create_clangxx_driver "$build_dir" "$clang")"
run_env_cmd "$toolchain_bin" "$clang" "$clangxx_driver" meson "${setup_args[@]}"

if [[ "$dry_run" == "true" ]]; then
    printf 'DRY-RUN: write %q for DinoX commit %q\n' \
        "$build_dir/$PROVENANCE_STAMP_NAME" "$dinox_source_commit"
else
    info "Recording clean DinoX wrapper build provenance"
    python3 "$PROVENANCE_CHECK" write-build-stamp \
        "$build_dir" "$PROJECT_ROOT" "$dinox_source_commit"
fi
