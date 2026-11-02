#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_ROOT="${DINOX_LINUX_VENDOR_ROOT:-$PROJECT_ROOT/.vendor-deps}"
install -d -m 0755 "$VENDOR_ROOT"
VENDOR_ROOT="$(cd "$VENDOR_ROOT" && pwd -P)"
DOWNLOAD_ROOT="$VENDOR_ROOT/downloads"
SOURCE_DEPS_ROOT="$VENDOR_ROOT/linux-source-deps"

VENDOR_DEPS_URL="https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps"

PROTOBUF_C_VERSION="1.5.2"
PROTOBUF_C_ARCHIVE="protobuf-c-$PROTOBUF_C_VERSION.tar.gz"
PROTOBUF_C_SHA256="e2c86271873a79c92b58fef7ebf8de1aa0df4738347a8bd5d4e65a80a16d0d24"

LIBOMEMO_C_VERSION="0.5.1"
LIBOMEMO_C_ARCHIVE="libomemo-c-$LIBOMEMO_C_VERSION.tar.gz"
LIBOMEMO_C_SHA512="ff59565406c51663f2944e9a7c12c5b0e3fa01073039f5161472dd81f59194b1cf2685bc1e0cc930a141bc409b965c5d93313cfc3e0e237250102af3b5e88826"

WEBRTC_ARCHIVE="libwebrtc-m152-linux-x86_64-runtime-abi40-ipc10-sha256-2479cdb9ab7e.tar.gz"
WEBRTC_SHA256="2479cdb9ab7eace826e28d519a9dd33478329e34c303ed716c196005d9cec46f"
WEBRTC_ROOT="$VENDOR_ROOT/libwebrtc-m152-linux-x86_64-runtime"
WEBRTC_ASSET_MARKER_NAME=".dinox-vendor-asset"
WEBRTC_CHECK_SCRIPT="$PROJECT_ROOT/scripts/check-libwebrtc-linux-runtime.sh"
WEBRTC_INSTALL_LOCK="$VENDOR_ROOT/.dinox-libwebrtc-runtime.lock"
WEBRTC_ROLLBACK_ROOT="$WEBRTC_ROOT.dinox-rollback"

usage() {
    cat <<EOF
Usage: $0 [--self-test|-h|--help]

Prepares the public, pinned dependencies used by a normal Linux source build:
  - protobuf-c $PROTOBUF_C_VERSION
  - libomemo-c $LIBOMEMO_C_VERSION
  - private IBus 1.5.30 client compatibility library
  - Google/libwebrtc M152 Linux runtime

Everything is installed below:
  $VENDOR_ROOT

No root privileges are used. Override that directory with
DINOX_LINUX_VENDOR_ROOT. DINOX_BUILD_JOBS (or DINOX_CI_JOBS) limits dependency
compilation parallelism; otherwise the detected CPU count is used.
Install the distribution packages listed in
docs/internal/BUILD.md before running this script.
EOF
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

build_job_count() {
    local jobs="${DINOX_BUILD_JOBS:-${DINOX_CI_JOBS:-$(nproc)}}"
    if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
        echo "FAIL: invalid DinoX build job limit: $jobs" >&2
        return 2
    fi
    printf '%s\n' "$jobs"
}

write_webrtc_asset_marker() {
    local runtime_root="$1"
    local marker="$runtime_root/$WEBRTC_ASSET_MARKER_NAME"
    local partial="$marker.part.$$"

    rm -f -- "$partial"
    {
        printf 'archive=%s\n' "$WEBRTC_ARCHIVE"
        printf 'sha256=%s\n' "$WEBRTC_SHA256"
    } > "$partial"
    chmod 0644 "$partial"
    mv -f -- "$partial" "$marker"
}

webrtc_asset_marker_matches() {
    local runtime_root="$1"
    local marker="$runtime_root/$WEBRTC_ASSET_MARKER_NAME"
    local archive_line
    local sha256_line
    local extra_line

    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    {
        IFS= read -r archive_line || return 1
        IFS= read -r sha256_line || return 1
        if IFS= read -r extra_line; then
            return 1
        fi
    } < "$marker"
    [[ "$archive_line" == "archive=$WEBRTC_ARCHIVE" ]] || return 1
    [[ "$sha256_line" == "sha256=$WEBRTC_SHA256" ]]
}

webrtc_runtime_matches_pinned_asset() {
    local runtime_root="$1"

    webrtc_asset_marker_matches "$runtime_root" || return 1
    "$WEBRTC_CHECK_SCRIPT" "$runtime_root" >/dev/null 2>&1
}

acquire_webrtc_install_lock() {
    local lock_dir="$WEBRTC_INSTALL_LOCK"
    local owner_pid=""

    if mkdir -- "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock_dir/pid" \
            || {
                rm -f -- "$lock_dir/pid"
                rmdir -- "$lock_dir" 2>/dev/null || true
                return 1
            }
        return 0
    fi

    [[ -d "$lock_dir" && ! -L "$lock_dir" ]] \
        || fail "unsafe Google/libwebrtc install lock: $lock_dir"
    if [[ -f "$lock_dir/pid" && ! -L "$lock_dir/pid" ]]; then
        IFS= read -r owner_pid < "$lock_dir/pid" || owner_pid=""
    fi
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
        fail "another Google/libwebrtc runtime installation is active (PID $owner_pid)"
    fi
    fail "stale Google/libwebrtc install lock found; verify no prepare process is active, then remove $lock_dir"
}

release_webrtc_install_lock() {
    local lock_dir="$WEBRTC_INSTALL_LOCK"
    local owner_pid=""

    if [[ -f "$lock_dir/pid" && ! -L "$lock_dir/pid" ]]; then
        IFS= read -r owner_pid < "$lock_dir/pid" || owner_pid=""
    fi
    if [[ "$owner_pid" == "$$" ]]; then
        rm -f -- "$lock_dir/pid"
        rmdir -- "$lock_dir" 2>/dev/null || true
    fi
}

recover_interrupted_webrtc_swap() {
    [[ -e "$WEBRTC_ROLLBACK_ROOT" || -L "$WEBRTC_ROLLBACK_ROOT" ]] || return 0

    if webrtc_runtime_matches_pinned_asset "$WEBRTC_ROOT"; then
        rm -rf -- "$WEBRTC_ROLLBACK_ROOT"
        return 0
    fi

    rm -rf -- "$WEBRTC_ROOT"
    mv -- "$WEBRTC_ROLLBACK_ROOT" "$WEBRTC_ROOT" \
        || fail "could not restore Google/libwebrtc runtime after an interrupted update"
    echo "==> Restored Google/libwebrtc runtime after an interrupted update"
}

install_staged_webrtc_runtime() {
    local staged_root="$1"
    local had_previous=0

    [[ ! -e "$WEBRTC_ROLLBACK_ROOT" && ! -L "$WEBRTC_ROLLBACK_ROOT" ]] \
        || return 1
    if [[ -e "$WEBRTC_ROOT" || -L "$WEBRTC_ROOT" ]]; then
        mv -- "$WEBRTC_ROOT" "$WEBRTC_ROLLBACK_ROOT" || return 1
        had_previous=1
    fi

    if mv -- "$staged_root" "$WEBRTC_ROOT" \
            && webrtc_runtime_matches_pinned_asset "$WEBRTC_ROOT"; then
        rm -rf -- "$WEBRTC_ROLLBACK_ROOT"
        return 0
    fi

    rm -rf -- "$WEBRTC_ROOT"
    if [[ "$had_previous" -eq 1 ]]; then
        mv -- "$WEBRTC_ROLLBACK_ROOT" "$WEBRTC_ROOT" || {
            echo "FAIL: runtime update failed and rollback is still at $WEBRTC_ROLLBACK_ROOT" >&2
            return 1
        }
    fi
    return 1
}

run_self_test() {
    local tmpdir
    local runtime_root
    local original_check_script
    local original_install_lock

    [[ "$(DINOX_BUILD_JOBS=2 DINOX_CI_JOBS=3 build_job_count)" == 2 ]] \
        || fail "build job limit did not prefer DINOX_BUILD_JOBS"
    [[ "$(DINOX_BUILD_JOBS= DINOX_CI_JOBS=3 build_job_count)" == 3 ]] \
        || fail "build job limit did not honor DINOX_CI_JOBS"
    local invalid_jobs
    for invalid_jobs in 0 -1 invalid '2 3'; do
        if (DINOX_BUILD_JOBS="$invalid_jobs" build_job_count) >/dev/null 2>&1; then
            fail "build job limit accepted $invalid_jobs"
        fi
    done

    tmpdir="$(mktemp -d)"
    trap 'rm -rf -- "$tmpdir"' RETURN
    runtime_root="$tmpdir/runtime"
    mkdir -p "$runtime_root"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmpdir/check-runtime"
    chmod 0755 "$tmpdir/check-runtime"
    original_check_script="$WEBRTC_CHECK_SCRIPT"
    original_install_lock="$WEBRTC_INSTALL_LOCK"
    WEBRTC_CHECK_SCRIPT="$tmpdir/check-runtime"
    WEBRTC_INSTALL_LOCK="$tmpdir/webrtc-install.lock"

    acquire_webrtc_install_lock \
        || fail "Google/libwebrtc install-lock self-test could not acquire the lock"
    if (acquire_webrtc_install_lock) >/dev/null 2>&1; then
        fail "Google/libwebrtc install-lock self-test allowed a concurrent writer"
    fi
    release_webrtc_install_lock
    [[ ! -e "$WEBRTC_INSTALL_LOCK" && ! -L "$WEBRTC_INSTALL_LOCK" ]] \
        || fail "Google/libwebrtc install-lock self-test did not release the lock"

    if webrtc_runtime_matches_pinned_asset "$runtime_root"; then
        fail "Google/libwebrtc cache self-test accepted a markerless ABI-compatible runtime"
    fi

    write_webrtc_asset_marker "$runtime_root"
    webrtc_runtime_matches_pinned_asset "$runtime_root" \
        || fail "Google/libwebrtc cache self-test rejected the current pinned runtime"

    printf '#!/usr/bin/env bash\nexit 1\n' > "$tmpdir/check-runtime"
    if webrtc_runtime_matches_pinned_asset "$runtime_root"; then
        fail "Google/libwebrtc cache self-test ignored a failing runtime checker"
    fi
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmpdir/check-runtime"

    printf 'archive=%s\n' "$WEBRTC_ARCHIVE" \
        > "$runtime_root/$WEBRTC_ASSET_MARKER_NAME"
    if webrtc_asset_marker_matches "$runtime_root"; then
        fail "Google/libwebrtc marker self-test accepted truncated metadata"
    fi

    printf 'archive=%s\nsha256=%064d\n' "$WEBRTC_ARCHIVE" 0 \
        > "$runtime_root/$WEBRTC_ASSET_MARKER_NAME"
    if webrtc_runtime_matches_pinned_asset "$runtime_root"; then
        fail "Google/libwebrtc cache self-test accepted a stale ABI-compatible runtime"
    fi

    {
        printf 'archive=%s\n' "$WEBRTC_ARCHIVE"
        printf 'sha256=%s\n' "$WEBRTC_SHA256"
        printf 'unexpected=field\n'
    } > "$runtime_root/$WEBRTC_ASSET_MARKER_NAME"
    if webrtc_asset_marker_matches "$runtime_root"; then
        fail "Google/libwebrtc marker self-test accepted extra metadata"
    fi

    WEBRTC_CHECK_SCRIPT="$original_check_script"
    WEBRTC_INSTALL_LOCK="$original_install_lock"
    rm -rf -- "$tmpdir"
    trap - RETURN
    echo "Self-test OK"
}

case "${1:-}" in
    "") ;;
    -h|--help)
        usage
        exit 0
        ;;
    --self-test)
        [[ "$#" -eq 1 ]] || { usage >&2; exit 2; }
        run_self_test
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

BUILD_JOBS="$(build_job_count)"

for command_name in cmake curl make meson ninja pkg-config python3 readelf sha256sum sha512sum tar; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "$command_name is required; install the BUILD.md package list first"
done
[[ "$(uname -s)" == "Linux" ]] || fail "this helper is only for Linux"
[[ "$(uname -m)" == "x86_64" ]] \
    || fail "the published Google/libwebrtc Linux runtime requires x86_64"

case "$SOURCE_DEPS_ROOT" in
    "$VENDOR_ROOT"/*) ;;
    *) fail "unsafe source dependency directory: $SOURCE_DEPS_ROOT" ;;
esac

install -d -m 0755 "$DOWNLOAD_ROOT"

download_and_verify() {
    local url="$1"
    local output="$2"
    local algorithm="$3"
    local expected="$4"
    local partial="$output.part"

    if [[ -s "$output" ]]; then
        if printf '%s  %s\n' "$expected" "$output" | "${algorithm}sum" --check --status; then
            echo "==> Using verified cached $(basename "$output")"
            return
        fi
        echo "==> Replacing corrupt $(basename "$output")"
        rm -f -- "$output"
    fi

    rm -f -- "$partial"
    echo "==> Downloading $(basename "$output")"
    curl --proto '=https' --tlsv1.2 --fail --location --show-error \
        --retry 3 --output "$partial" "$url"
    printf '%s  %s\n' "$expected" "$partial" | "${algorithm}sum" --check --status \
        || fail "checksum mismatch for $(basename "$output")"
    mv -- "$partial" "$output"
}

require_archive_root() {
    local archive="$1"
    local expected_root="$2"
    python3 - "$archive" "$expected_root" <<'PY'
import posixpath
import sys
import tarfile

archive, root = sys.argv[1:]
seen = False

def inside_root(path):
    return path == root or path.startswith(root + "/")

with tarfile.open(archive, "r:gz") as source:
    for member in source:
        seen = True
        name = posixpath.normpath(member.name)
        if member.name.startswith("/") or not inside_root(name):
            raise SystemExit(
                f"FAIL: archive entry escapes expected root {root}: {member.name}")
        if member.issym():
            target = posixpath.normpath(
                posixpath.join(posixpath.dirname(name), member.linkname))
            if member.linkname.startswith("/") or not inside_root(target):
                raise SystemExit(
                    f"FAIL: archive symlink escapes expected root {root}: "
                    f"{member.name} -> {member.linkname}")
        elif member.islnk():
            target = posixpath.normpath(member.linkname)
            if member.linkname.startswith("/") or not inside_root(target):
                raise SystemExit(
                    f"FAIL: archive hardlink escapes expected root {root}: "
                    f"{member.name} -> {member.linkname}")

if not seen:
    raise SystemExit(f"FAIL: archive is empty: {archive}")
PY
}

PROTOBUF_C_PATH="$DOWNLOAD_ROOT/$PROTOBUF_C_ARCHIVE"
LIBOMEMO_C_PATH="$DOWNLOAD_ROOT/$LIBOMEMO_C_ARCHIVE"
WEBRTC_PATH="$DOWNLOAD_ROOT/$WEBRTC_ARCHIVE"

download_and_verify \
    "$VENDOR_DEPS_URL/$PROTOBUF_C_ARCHIVE" \
    "$PROTOBUF_C_PATH" sha256 "$PROTOBUF_C_SHA256"
download_and_verify \
    "$VENDOR_DEPS_URL/$LIBOMEMO_C_ARCHIVE" \
    "$LIBOMEMO_C_PATH" sha512 "$LIBOMEMO_C_SHA512"

require_archive_root "$PROTOBUF_C_PATH" "protobuf-c-$PROTOBUF_C_VERSION"
require_archive_root "$LIBOMEMO_C_PATH" "libomemo-c-$LIBOMEMO_C_VERSION"

prepare_webrtc_runtime() (
    local work=""
    local staged_root

    acquire_webrtc_install_lock \
        || fail "could not create Google/libwebrtc install lock"
    trap 'status=$?; set +e; if [[ -n "$work" ]]; then rm -rf -- "$work"; fi; release_webrtc_install_lock; exit "$status"' EXIT
    recover_interrupted_webrtc_swap

    if webrtc_runtime_matches_pinned_asset "$WEBRTC_ROOT"; then
        echo "==> Google/libwebrtc M152 runtime already validated"
        return 0
    fi

    download_and_verify \
        "$VENDOR_DEPS_URL/$WEBRTC_ARCHIVE" \
        "$WEBRTC_PATH" sha256 "$WEBRTC_SHA256"
    require_archive_root "$WEBRTC_PATH" "libwebrtc-m152-linux-x86_64-runtime"

    echo "==> Extracting verified Google/libwebrtc runtime"
    work="$(mktemp -d "$VENDOR_ROOT/libwebrtc-unpack.XXXXXX")"
    tar -xzf "$WEBRTC_PATH" -C "$work"
    staged_root="$work/libwebrtc-m152-linux-x86_64-runtime"
    [[ -d "$staged_root" && ! -L "$staged_root" ]] \
        || fail "unexpected Google/libwebrtc runtime archive layout"
    "$WEBRTC_CHECK_SCRIPT" "$staged_root"
    write_webrtc_asset_marker "$staged_root"
    webrtc_runtime_matches_pinned_asset "$staged_root" \
        || fail "staged Google/libwebrtc runtime does not match the repository pin"
    install_staged_webrtc_runtime "$staged_root" \
        || fail "could not install Google/libwebrtc runtime; previous runtime restored"
)

prepare_webrtc_runtime

validate_source_deps() {
    local pkg_config_dir="$SOURCE_DEPS_ROOT/lib/pkgconfig"
    local ldd_output

    [[ -f "$SOURCE_DEPS_ROOT/.dinox-source-deps" ]] || return 1
    grep -Fx "protobuf-c=$PROTOBUF_C_VERSION" "$SOURCE_DEPS_ROOT/.dinox-source-deps" >/dev/null \
        || return 1
    grep -Fx "libomemo-c=$LIBOMEMO_C_VERSION" "$SOURCE_DEPS_ROOT/.dinox-source-deps" >/dev/null \
        || return 1
    PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$pkg_config_dir" \
        pkg-config --exact-version="$PROTOBUF_C_VERSION" libprotobuf-c \
        || return 1
    PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$pkg_config_dir" \
        pkg-config --exact-version="$LIBOMEMO_C_VERSION" libomemo-c \
        || return 1
    [[ -s "$SOURCE_DEPS_ROOT/lib/libprotobuf-c.so.1.0.0" ]] || return 1
    [[ -s "$SOURCE_DEPS_ROOT/lib/libomemo-c.so.0.5.1" ]] || return 1
    readelf -d "$SOURCE_DEPS_ROOT/lib/libomemo-c.so.0.5.1" \
        | grep -F 'Library runpath: [$ORIGIN]' >/dev/null \
        || return 1
    ldd_output="$(ldd "$SOURCE_DEPS_ROOT/lib/libomemo-c.so.0.5.1" 2>&1)" \
        || return 1
    grep -F "$SOURCE_DEPS_ROOT/lib/libprotobuf-c.so.1" <<<"$ldd_output" >/dev/null \
        || return 1
}

if validate_source_deps; then
    echo "==> Using validated protobuf-c $PROTOBUF_C_VERSION and libomemo-c $LIBOMEMO_C_VERSION"
else
    echo "==> Building pinned Linux encryption dependencies"
    rm -rf -- "$SOURCE_DEPS_ROOT"
    install -d -m 0755 "$SOURCE_DEPS_ROOT"
    BUILD_ROOT="$(mktemp -d "$VENDOR_ROOT/.build-linux-source-deps.XXXXXX")"
    trap 'rm -rf -- "$BUILD_ROOT"' EXIT

    tar -xzf "$PROTOBUF_C_PATH" -C "$BUILD_ROOT"
    (
        cd "$BUILD_ROOT/protobuf-c-$PROTOBUF_C_VERSION"
        ./configure \
            --prefix="$SOURCE_DEPS_ROOT" \
            --libdir="$SOURCE_DEPS_ROOT/lib" \
            --disable-protoc
        make -j"$BUILD_JOBS"
        make install
    )

    tar -xzf "$LIBOMEMO_C_PATH" -C "$BUILD_ROOT"
    LIBOMEMO_SOURCE="$BUILD_ROOT/libomemo-c-$LIBOMEMO_C_VERSION"
    grep -Fx 'Cflags: -I${includedir}/omemo' \
        "$LIBOMEMO_SOURCE/src/libomemo-c.pc.in" >/dev/null \
        || fail "unexpected upstream libomemo-c pkg-config include flags"
    sed -i 's|^Cflags: -I${includedir}/omemo$|Cflags: -I${includedir}|' \
        "$LIBOMEMO_SOURCE/src/libomemo-c.pc.in"
    grep -Fx 'Cflags: -I${includedir}' \
        "$LIBOMEMO_SOURCE/src/libomemo-c.pc.in" >/dev/null \
        || fail "failed to correct libomemo-c pkg-config include root"

    cmake -S "$LIBOMEMO_SOURCE" -B "$LIBOMEMO_SOURCE/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$SOURCE_DEPS_ROOT" \
        '-DCMAKE_INSTALL_RPATH=$ORIGIN' \
        -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=FALSE \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_TESTING=OFF \
        -DPBC_LIB="$SOURCE_DEPS_ROOT/lib/libprotobuf-c.so" \
        -DCMAKE_C_FLAGS="-I$SOURCE_DEPS_ROOT/include"
    cmake --build "$LIBOMEMO_SOURCE/build" --parallel "$BUILD_JOBS"
    cmake --install "$LIBOMEMO_SOURCE/build"

    printf 'protobuf-c=%s\nlibomemo-c=%s\n' \
        "$PROTOBUF_C_VERSION" "$LIBOMEMO_C_VERSION" \
        > "$SOURCE_DEPS_ROOT/.dinox-source-deps"
    validate_source_deps \
        || fail "the prepared Linux encryption dependency runtime is incomplete"
fi

bash "$PROJECT_ROOT/scripts/prepare-ibus-compat.sh" --prefix "$SOURCE_DEPS_ROOT"

cat <<EOF
OK: normal Linux source-build dependencies are ready
  Google/libwebrtc: $WEBRTC_ROOT
  protobuf-c/libomemo-c: $SOURCE_DEPS_ROOT
  private IBus: $SOURCE_DEPS_ROOT/lib/dinox/ibus-compat/libibus-1.0.so.5.0.530
EOF
