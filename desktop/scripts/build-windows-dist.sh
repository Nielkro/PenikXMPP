#!/usr/bin/env bash
set -euo pipefail

# Meson's redirected progress/log paths must remain printable in Unicode roots.
export PYTHONUTF8=1

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PARENT="$(cd "$PROJECT_ROOT/.." && pwd)"
DEFAULT_VENDOR_ROOT="${DINOX_WINDOWS_VENDOR_ROOT:-$PROJECT_PARENT/vendor-deps}"
DEFAULT_RUNTIME_ROOT="$DEFAULT_VENDOR_ROOT/libwebrtc-m152-windows-x86_64"
DEFAULT_LYREBIRD_PATH="$DEFAULT_VENDOR_ROOT/lyrebird-0.8.1/lyrebird.exe"
PANGO_PACKAGE_NAME="mingw-w64-x86_64-pango"
PANGO_REQUIRED_PACKAGE_VERSION="1.56.4-3"
RUNTIME_ROOT="${DINOX_GOOGLE_WEBRTC_RUNTIME_ROOT:-$DEFAULT_RUNTIME_ROOT}"
LYREBIRD_PATH="${DINOX_LYREBIRD_PATH:-$DEFAULT_LYREBIRD_PATH}"
BUILD_TYPE="${DINOX_WINDOWS_BUILD_TYPE:-release}"
case "$BUILD_TYPE" in
    release) BUILD_DEBUG=false ;;
    debugoptimized) BUILD_DEBUG=true ;;
    *) echo "Invalid Windows build type: $BUILD_TYPE (expected release or debugoptimized)" >&2; exit 2 ;;
esac

NINJA_ARGS=()
if [ -n "${DINOX_BUILD_JOBS:-${DINOX_CI_JOBS:-}}" ]; then
    DINOX_EFFECTIVE_JOBS="${DINOX_BUILD_JOBS:-${DINOX_CI_JOBS:-}}"
    if ! [[ "$DINOX_EFFECTIVE_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        echo "Invalid DINOX build job limit: $DINOX_EFFECTIVE_JOBS" >&2
        exit 2
    fi
    NINJA_ARGS=(-j "$DINOX_EFFECTIVE_JOBS")
fi

MESON_OPTIONS=(
    "-Dbuildtype=$BUILD_TYPE"
    -Doptimization=2
    "-Ddebug=$BUILD_DEBUG"
    -Dplugin-rtp=disabled
    -Dplugin-google-webrtc=enabled
    -Dgoogle-libwebrtc-wrapper=enabled
    "-Dgoogle-libwebrtc-runtime-root=$RUNTIME_ROOT"
    -Dgoogle-libwebrtc-test-oracle=false
    -Dgoogle-libwebrtc-tests=false
    -Dplugin-omemo=enabled
    -Dplugin-openpgp=enabled
    -Dplugin-ice=enabled
    -Dplugin-http-files=enabled
    -Dplugin-mqtt=enabled
    -Ddnssec=enabled
    -Dplugin-notification-sound=enabled
    -Dlocation-sharing=disabled
)

usage() {
    echo "Usage: $0 [--self-test|-h|--help]"
    echo
    echo "Creates the supported portable DinoX Windows test distribution:"
    echo "  $PROJECT_ROOT/dist/dinox.exe"
    echo
    echo "Run as your normal Windows user; elevated Administrator builds are refused."
    echo "Console output is also saved to a unique compile-*.log in ~/dinox-build-logs."
    echo "Set DINOX_WINDOWS_LOG_DIR to choose another directory outside the checkout."
    echo "The script removes build/ and dist/, validates Pango/Tor/Lyrebird and the"
    echo "pinned Google/libwebrtc runtime, configures the production plugin profile,"
    echo "performs a full build, runs native smokes and validates the DLL closure."
    echo "Prepare a fresh public build environment first with:"
    echo "  bash \"$PROJECT_ROOT/scripts/prepare-windows-build-deps.sh\""
    echo "Set DINOX_BUILD_JOBS (or DINOX_CI_JOBS) to limit concurrent compile jobs."
    echo "Set DINOX_WINDOWS_UI_TESTS=1 only from an interactive desktop to run the GTK widget tests."
    echo "The default is release with -O2 and no debug symbols."
    echo "Set DINOX_WINDOWS_BUILD_TYPE=debugoptimized only for developer builds."
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_standard_windows_user() {
    if [ "${DINOX_ALLOW_ADMIN:-0}" = "1" ]; then
        return 0
    fi
    local status=0
    command -v powershell.exe >/dev/null 2>&1 \
        || fail "PowerShell is required to check Windows privileges before deleting build/ or dist/."
    # Check the active UAC token, not account/group names or MSYS2's uid.
    powershell.exe -NoProfile -NonInteractive -Command '
        $ErrorActionPreference = "Stop"
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
        if ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 10 }
        exit 0
    ' || status=$?
    case "$status" in
        0) ;;
        10) fail "Do not build as Administrator. Open MSYS2 MINGW64 as your normal Windows user and run this command again. No build or dist files were changed." ;;
        *) fail "Could not verify the Windows process privileges (PowerShell exit $status). No build or dist files were changed." ;;
    esac
}

run_logged_build() {
    local log_dir log_file source_root command_name status footer warning_report
    local -a result
    for command_name in tee mktemp realpath date python3; do
        command -v "$command_name" >/dev/null 2>&1 \
            || fail "required build logging command not found: $command_name"
    done
    source_root="$(cd "$PROJECT_ROOT" && pwd -P)"
    log_dir="$(realpath -m -- "${DINOX_WINDOWS_LOG_DIR:-$HOME/dinox-build-logs}")"
    case "$log_dir/" in
        "$source_root/"*) fail "DINOX_WINDOWS_LOG_DIR must be outside the checkout so clean builds preserve their logs." ;;
    esac
    mkdir -p -- "$log_dir" || fail "cannot create build log directory: $log_dir"
    log_file="$(mktemp "$log_dir/compile-$(date +%Y%m%d-%H%M%S)-XXXXXX.log")" \
        || fail "cannot create build log in: $log_dir"
    printf 'BUILD_LOG=%s\n' "$log_file"

    # Keep errexit inside the build; only the parent captures both pipeline
    # statuses. A successful tee must never turn a failed compiler into success.
    set +e
    (
        set -e
        printf '==> Started: %s\n' "$(date -Is)"
        printf '==> Build user: %s\n' "$(id -un)"
        printf '==> Source: %s\n' "$PROJECT_ROOT"
        printf '==> Source commit: %s\n' "$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"
        printf 'BUILD_LOG=%s\n' "$log_file"
        "$@"
    ) 2>&1 | tee -a "$log_file"
    result=("${PIPESTATUS[@]}")
    set -e
    status="${result[0]}"
    if [ "${result[1]}" -ne 0 ]; then
        echo "FAIL: build log could not be written completely: $log_file" >&2
        [ "$status" -ne 0 ] || status="${result[1]}"
    fi
    # Summarize every phase, not only build.sh's later incremental test build.
    # Report failures too, without replacing the original compiler exit code.
    if warning_report="$(python3 "$PROJECT_ROOT/scripts/compiler-warning-report.py" "$log_file")"; then
        if ! printf '%s\n' "$warning_report" | tee -a "$log_file"; then
            [ "$status" -ne 0 ] || status=1
        fi
    else
        echo "FAIL: could not summarize compiler warnings: $log_file" >&2
        [ "$status" -ne 0 ] || status=1
    fi
    printf -v footer '==> Finished: %s\nWINDOWS_BUILD_EXIT_CODE=%s\nBUILD_LOG=%s' \
        "$(date -Is)" "$status" "$log_file"
    if ! printf '%s\n' "$footer" | tee -a "$log_file"; then
        echo "FAIL: could not write the build log summary: $log_file" >&2
        [ "$status" -ne 0 ] || status=1
    fi
    return "$status"
}

remove_failed_dist() {
    local status=$?
    trap - EXIT

    if [ -d "$PROJECT_ROOT/build/meson-private" ]; then
        meson setup --reconfigure "$PROJECT_ROOT/build" \
            -Dgoogle-libwebrtc-tests=false >/dev/null 2>&1 || true
    fi

    if [ "$status" -ne 0 ]; then
        echo "FAIL: Windows distribution build failed; removing dist/" >&2
        if ! rm -rf -- "$PROJECT_ROOT/dist"; then
            echo "FAIL: dist/ could not be removed. Close DinoX and check ownership/access rights; do not rebuild as Administrator." >&2
        fi
    fi

    exit "$status"
}

has_meson_option() {
    local expected="$1"
    local option
    for option in "${MESON_OPTIONS[@]}"; do
        if [ "$option" = "$expected" ]; then
            return 0
        fi
    done
    return 1
}

require_pango_package_version() {
    local query_output
    local installed_version

    if ! query_output="$(pacman -Q "$PANGO_PACKAGE_NAME" 2>/dev/null)"; then
        fail "required MSYS2 package is not installed: $PANGO_PACKAGE_NAME"
    fi
    installed_version="${query_output#"$PANGO_PACKAGE_NAME "}"
    if [ "$installed_version" != "$PANGO_REQUIRED_PACKAGE_VERSION" ]; then
        fail "$PANGO_PACKAGE_NAME $installed_version is not the validated Windows runtime; expected $PANGO_REQUIRED_PACKAGE_VERSION (affected Pango 1.57/1.58 builds break Win32 color emoji)"
    fi
    echo "==> Validated Pango runtime: $PANGO_PACKAGE_NAME $installed_version"
}

run_session_self_test() (
    local fixture status log_file count token_status
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "$fixture"' EXIT
    mkdir -p "$fixture/Source with spaces/scripts" "$fixture/Logs Ünicode"
    cp "$PROJECT_ROOT/scripts/compiler-warning-report.py" "$fixture/Source with spaces/scripts/"
    PROJECT_ROOT="$fixture/Source with spaces"
    export DINOX_WINDOWS_LOG_DIR="$fixture/Logs Ünicode"

    fixture_build() {
        echo "fixture preflight stdout"
        echo "fixture compiler stderr" >&2
        echo 'source.c:1:2: warning: fixture warning [-Wunused-label]' >&2
        echo 'Warnings in this invocation: 0' # A later phase must not erase it.
        if [ "$1" = fail ]; then
            trap 'echo "fixture failure cleanup"' EXIT
            bash -c 'exit 17'
            echo "UNREACHABLE after compiler error"
        fi
        echo "fixture package gate stdout"
    }

    (run_logged_build fixture_build success) >"$fixture/success.out" 2>&1
    log_file="$(sed -n 's/^BUILD_LOG=//p' "$fixture/success.out" | head -n 1)"
    [ -s "$log_file" ] || fail "self-test did not produce a persistent log"
    for output in 'fixture preflight stdout' 'fixture compiler stderr' \
                  'fixture package gate stdout' 'WINDOWS_BUILD_EXIT_CODE=0' \
                  'WINDOWS_COMPILER_WARNING_COUNT=1'; do
        grep -F "$output" "$log_file" >/dev/null || fail "self-test log omitted $output"
        grep -F "$output" "$fixture/success.out" >/dev/null || fail "self-test console omitted $output"
    done
    set +e
    (set -e; run_logged_build fixture_build fail) >"$fixture/fail.out" 2>&1
    status=$?
    set -e
    [ "$status" -eq 17 ] || fail "self-test logger hid compiler failure: $status"
    log_file="$(sed -n 's/^BUILD_LOG=//p' "$fixture/fail.out" | head -n 1)"
    grep -F 'fixture failure cleanup' "$log_file" >/dev/null || fail "self-test omitted cleanup output"
    grep -F 'WINDOWS_BUILD_EXIT_CODE=17' "$log_file" >/dev/null || fail "self-test omitted failure status"
    grep -F 'WINDOWS_COMPILER_WARNING_COUNT=1' "$log_file" >/dev/null || fail "self-test omitted warnings on failure"
    if grep -F 'UNREACHABLE' "$log_file" >/dev/null; then
        fail "self-test continued after a compiler failure"
    fi
    count="$(find "$DINOX_WINDOWS_LOG_DIR" -name 'compile-*.log' -type f | wc -l)"
    [ "$count" -eq 2 ] || fail "self-test reused a previous log"

    set +e
    (
        set -e
        # A failed log writer must fail an otherwise successful build.
        tee() { cat >/dev/null; return 7; }
        run_logged_build fixture_build success
    ) >"$fixture/tee.out" 2>&1
    status=$?
    set -e
    [ "$status" -eq 7 ] || fail "self-test hid the log writer's failure: $status"

    set +e
    (set -e; DINOX_WINDOWS_LOG_DIR="$PROJECT_ROOT/build/logs" run_logged_build fixture_build success) \
        >"$fixture/inside.out" 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "self-test accepted logs inside the checkout"
    [ ! -e "$PROJECT_ROOT/build" ] || fail "self-test created logs inside build/"

    # Run the real entry point with a simulated Windows token. Refusals must
    # happen before cleanup or creating any Administrator-owned log files.
    cp -- "$0" "$PROJECT_ROOT/scripts/build-windows-dist.sh"
    mkdir -p "$fixture/bin" "$PROJECT_ROOT/build" "$PROJECT_ROOT/dist"
    printf 'keep\n' >"$PROJECT_ROOT/build/canary"
    printf 'keep\n' >"$PROJECT_ROOT/dist/canary"
    printf '#!/usr/bin/env bash\nprintf "MINGW64_NT_TEST\\n"\n' >"$fixture/bin/uname"
    printf '#!/usr/bin/env bash\nexit "${DINOX_FIXTURE_ADMIN_EXIT:-10}"\n' >"$fixture/bin/powershell.exe"
    chmod +x "$fixture/bin/uname" "$fixture/bin/powershell.exe"
    for token_status in 10 23; do
        set +e
        PATH="$fixture/bin:$PATH" DINOX_FIXTURE_ADMIN_EXIT="$token_status" \
            DINOX_WINDOWS_LOG_DIR="$fixture/rejected-logs" \
            bash "$PROJECT_ROOT/scripts/build-windows-dist.sh" >"$fixture/token.out" 2>&1
        status=$?
        set -e
        [ "$status" -ne 0 ] || fail "self-test accepted elevated/unknown Windows privileges"
        [ -f "$PROJECT_ROOT/build/canary" ] && [ -f "$PROJECT_ROOT/dist/canary" ] \
            || fail "self-test privilege refusal deleted build artifacts"
        [ ! -e "$fixture/rejected-logs" ] || fail "self-test privilege refusal created logs"
    done
    PATH="$fixture/bin:$PATH" DINOX_FIXTURE_ADMIN_EXIT=0 require_standard_windows_user
    set +e
    PATH="$fixture/bin:$PATH" DINOX_FIXTURE_ADMIN_EXIT=0 \
        DINOX_WINDOWS_LOG_DIR="$fixture/normal-logs" \
        DINOX_GOOGLE_WEBRTC_RUNTIME_ROOT="$fixture/missing-runtime" \
        bash "$PROJECT_ROOT/scripts/build-windows-dist.sh" >"$fixture/normal.out" 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "self-test unexpectedly built without a runtime"
    [ ! -e "$PROJECT_ROOT/build/canary" ] && [ ! -e "$PROJECT_ROOT/dist/canary" ] \
        || fail "self-test normal user did not reach clean-build preparation"
    log_file="$(sed -n 's/^BUILD_LOG=//p' "$fixture/normal.out" | head -n 1)"
    grep -F 'Removing all previous Windows build and dist artifacts' "$log_file" >/dev/null \
        || fail "self-test did not log actual entry-point cleanup"
    grep -F 'Windows distribution build failed; removing dist/' "$log_file" >/dev/null \
        || fail "self-test did not log the actual failed-build cleanup"
    grep -F "WINDOWS_BUILD_EXIT_CODE=$status" "$log_file" >/dev/null \
        || fail "self-test actual entry-point status differs from its log"
    echo "Windows build session self-test OK (logs, exit status, permissions)"
)

run_self_test() {
    run_session_self_test
    local expected
    for expected in \
        "-Dbuildtype=$BUILD_TYPE" \
        -Doptimization=2 \
        "-Ddebug=$BUILD_DEBUG" \
        -Dplugin-rtp=disabled \
        -Dplugin-google-webrtc=enabled \
        -Dgoogle-libwebrtc-wrapper=enabled \
        -Dgoogle-libwebrtc-test-oracle=false \
        -Dgoogle-libwebrtc-tests=false \
        -Dplugin-omemo=enabled \
        -Dplugin-openpgp=enabled \
        -Dplugin-ice=enabled \
        -Dplugin-http-files=enabled \
        -Dplugin-mqtt=enabled \
        -Ddnssec=enabled \
        -Dplugin-notification-sound=enabled \
        -Dlocation-sharing=disabled; do
        has_meson_option "$expected" || fail "self-test missing Meson option: $expected"
    done
    has_meson_option "-Dgoogle-libwebrtc-runtime-root=$RUNTIME_ROOT" \
        || fail "self-test missing the canonical runtime root"
    if has_meson_option -Dplugin-rtp=enabled; then
        fail "self-test found the legacy RTP profile"
    fi
    "$0" --help >/dev/null || fail "self-test help failed"
    if "$0" --invalid >/dev/null 2>&1; then
        fail "self-test accepted an unknown option"
    fi
    DINOX_WINDOWS_BUILD_TYPE=release "$0" --help >/dev/null \
        || fail "self-test rejected the release profile"
    DINOX_WINDOWS_BUILD_TYPE=debugoptimized "$0" --help >/dev/null \
        || fail "self-test rejected the developer profile"
    if DINOX_WINDOWS_BUILD_TYPE=debug "$0" --help >/dev/null 2>&1; then
        fail "self-test accepted an unoptimized Windows build type"
    fi
    bash "$PROJECT_ROOT/scripts/update_dist.sh" --self-test >/dev/null \
        || fail "update_dist helper self-test failed"
    bash "$PROJECT_ROOT/scripts/check-windows-dist.sh" --self-test >/dev/null \
        || fail "Windows distribution checker self-test failed"
    bash "$PROJECT_ROOT/scripts/prepare-windows-build-deps.sh" --self-test >/dev/null \
        || fail "Windows dependency helper self-test failed"
    python3 "$PROJECT_ROOT/scripts/windows-license-inventory.py" self-test >/dev/null \
        || fail "Windows license inventory self-test failed"
    python3 "$PROJECT_ROOT/scripts/compiler-warning-report.py" --self-test >/dev/null \
        || fail "Compiler warning parser self-test failed"
    python3 "$PROJECT_ROOT/scripts/windows-compiler-paths.py" --self-test >/dev/null \
        || fail "Windows compiler Unicode path adapter self-test failed"
    bash "$PROJECT_ROOT/scripts/package-windows-dist.sh" --self-test >/dev/null \
        || fail "Windows ZIP packager self-test failed"
    grep -F 'windows-license-inventory.py stage' \
        "$PROJECT_ROOT/scripts/update_dist.sh" >/dev/null \
        || fail "update_dist does not stage the complete Windows PE license inventory"
    grep -F 'windows-license-inventory.py" verify' \
        "$PROJECT_ROOT/scripts/check-windows-dist.sh" >/dev/null \
        || fail "portable Windows license inventory gate is missing"
    grep -F -- '--runtime-smoke' "$PROJECT_ROOT/main/src/main.vala" >/dev/null \
        || fail "DinoX Windows runtime smoke option is missing"
    grep -F 'DINOX_RUNTIME_SMOKE_LANGUAGE' "$PROJECT_ROOT/main/src/main.vala" >/dev/null \
        || fail "DinoX Windows translation runtime smoke is missing"
    grep -F 'RuntimeSmokeRegisterPluginFunction' "$PROJECT_ROOT/main/src/main.vala" >/dev/null \
        || fail "DinoX Windows plugin registration smoke is missing"
    grep -F 'GLib.Win32.get_command_line()' "$PROJECT_ROOT/main/src/main.vala" >/dev/null \
        || fail "DinoX Windows UTF-8 command-line handling is missing"
    grep -F 'new Gdk.Pixbuf.from_file(runtime_icon_path)' \
        "$PROJECT_ROOT/main/src/main.vala" >/dev/null \
        || fail "DinoX Windows bundled PNG runtime smoke is missing"
    grep -F 'g_fopen(output_path, "wb")' \
        "$PROJECT_ROOT/main/src/ui/certstore_win32.c" >/dev/null \
        || fail "DinoX Windows certificate export is not Unicode-path safe"
    grep -F 'CertstoreWin32.get_active_code_page()' \
        "$PROJECT_ROOT/main/src/main.vala" >/dev/null \
        || fail "DinoX Windows UTF-8 process-code-page runtime gate is missing"
    grep -F '<activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>' \
        "$PROJECT_ROOT/main/data/dinox.exe.manifest" >/dev/null \
        || fail "DinoX Windows UTF-8 process manifest is missing"
    grep -F '1 24 "dinox.exe.manifest"' \
        "$PROJECT_ROOT/main/data/dinox.rc" >/dev/null \
        || fail "DinoX Windows UTF-8 process manifest is not embedded"
    grep -F 'XDG_DATA_HOME="$unicode_data_native"' \
        "$PROJECT_ROOT/scripts/check-windows-dist.sh" >/dev/null \
        || fail "portable Windows Unicode-path runtime smoke is missing"
    grep -F -- '--runtime-smoke' "$PROJECT_ROOT/scripts/check-windows-dist.sh" >/dev/null \
        || fail "portable Windows runtime smoke gate is missing"
    grep -F 'google-webrtc-media-foundation-writer-smoke' "$0" >/dev/null \
        || fail "Windows Media Foundation smoke is not run by the distribution builder"
    grep -F 'Strict test build and Google/libwebrtc Windows smokes' "$0" >/dev/null \
        || fail "Windows Google/libwebrtc test profile has no strict build gate"
    grep -F "'-Wno-unused-function'," \
        "$PROJECT_ROOT/plugins/google-webrtc/meson.build" >/dev/null \
        || fail "Windows Google/libwebrtc generated-C function warning filter is missing"
    grep -F "'-Wno-unused-label'," \
        "$PROJECT_ROOT/plugins/google-webrtc/meson.build" >/dev/null \
        || fail "Windows Google/libwebrtc generated-C label warning filter is missing"
    local batch_source="$PROJECT_ROOT/main/src/ui/application.vala"
    grep -F '@chcp 65001 >nul 2>&1 || exit /b 1\r\n' "$batch_source" >/dev/null \
        || fail "Windows deferred batch files do not select the UTF-8 code page"
    grep -F 'return value.replace ("%", "%%").replace ("/", "\\");' \
        "$batch_source" >/dev/null \
        || fail "Windows deferred batch paths are not escaped consistently"
    local batch_prelude_count
    batch_prelude_count="$(grep -Fc 'string batch_content = windows_batch_prelude ();' \
        "$batch_source")"
    [ "$batch_prelude_count" -eq 1 ] \
        || fail "expected the shared Windows profile restart to use the UTF-8 prelude"
    local batch_path_count
    batch_path_count="$(grep -Fc 'return windows_batch_set_path (' \
        "$batch_source")"
    [ "$batch_path_count" -eq 1 ] \
        || fail "expected the Windows restart directory to use the escaped path helper"
    local batch_restart_count
    batch_restart_count="$(grep -Fc \
        'batch_content += windows_batch_set_restart_executable' \
        "$batch_source")"
    [ "$batch_restart_count" -eq 1 ] \
        || fail "expected the shared Windows profile restart to use the safe restart helper"
    grep -F '"start \"\" \"dinox.exe\"" + (deletion_only ? " --apply-pending-profile-deletion" : (maintenance ? " --complete-profile-maintenance" : ""))' \
        "$batch_source" >/dev/null \
        || fail "Windows profile restarts do not use the fixed executable and internal operation flags"
    grep -F 'batch_content += windows_batch_start_restart_executable (deletion_only, true);' \
        "$batch_source" >/dev/null \
        || fail "Windows profile operations do not restart through the offline maintenance entrypoint"
    grep -F 'launcher.set_cwd (batch_dir);' "$batch_source" >/dev/null \
        || fail "Windows deferred batches do not use a Unicode-safe process cwd"
    grep -F 'Path.build_filename (system32_dir, "cmd.exe"),' \
        "$batch_source" >/dev/null \
        || fail "Windows deferred batches do not use the absolute System32 cmd.exe"
    grep -F 'launcher.setenv ("DINOX_SYSTEM32", system32_dir, true);' \
        "$batch_source" >/dev/null \
        || fail "Windows deferred batches do not pin external commands to System32"
    local deferred_batch_spawn_count
    deferred_batch_spawn_count="$(grep -Fc 'spawn_windows_deferred_batch (batch_path);' \
        "$batch_source")"
    [ "$deferred_batch_spawn_count" -eq 1 ] \
        || fail "expected the shared Windows profile restart to use the safe launcher"
    python3 "$PROJECT_ROOT/main/tests/windows_backup_unicode_regression_test.py" \
        "$batch_source" "$PROJECT_ROOT/main/src/main.vala" >/dev/null \
        || fail "Windows backup tar streaming/OpenSSL call-shape gate failed"
    echo "Self-test OK"
}

case "${1:-}" in
    -h|--help)
        [ "$#" -eq 1 ] || { usage >&2; exit 2; }
        usage
        exit 0
        ;;
    --self-test)
        [ "$#" -eq 1 ] || { usage >&2; exit 2; }
        run_self_test
        exit 0
        ;;
    "")
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }

case "$(uname -s)" in
    MINGW*|MSYS*) ;;
    *) fail "the Windows distribution must be built inside MSYS2/MINGW64" ;;
esac

require_standard_windows_user

build_windows_distribution() {
    cd "$PROJECT_ROOT"

    # Invalidate every earlier build before any preflight can fail.  Once this
    # command starts there must never be an older dist/dinox.exe left for testing.
    trap remove_failed_dist EXIT
    echo "==> Removing all previous Windows build and dist artifacts"
    if ! rm -rf -- build dist; then
        fail "Could not remove build/ or dist/. Close DinoX and other tools using these files. If an earlier Administrator build owns them, remove only these generated directories once with Administrator rights, then return to a normal MINGW64 shell."
    fi

    export PATH="/mingw64/bin:/usr/bin:$PATH"
    for command_name in git meson ninja python3 objdump strings ldd sha256sum pacman cygpath pkg-config; do
        command -v "$command_name" >/dev/null 2>&1 \
            || fail "required MINGW64 build command not found: $command_name"
    done

    pkg-config --exists libarchive \
        || fail "native libarchive is required for backups; install mingw-w64-x86_64-libarchive"

    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || fail "source root is not a Git checkout: $PROJECT_ROOT"
    [ -d "$RUNTIME_ROOT" ] || fail "Google/libwebrtc runtime root not found: $RUNTIME_ROOT"
    require_pango_package_version
    bash scripts/prepare-windows-tls.sh
    export GIO_MODULE_DIR="$(cygpath -m "$DEFAULT_VENDOR_ROOT/glib-networking-2.80.1-dinox/lib/gio/modules")"
    pkg-config --atleast-version=1.19 libunbound \
        || fail "DNSSEC/DANE requires mingw-w64-x86_64-unbound >= 1.19"
    python3 -c 'import dns.dnssec, cryptography, h2.connection' \
        || fail "DNSSEC tests require the documented MSYS2 Python dnspython, cryptography and h2 packages"
    bash scripts/check-windows-dist.sh --pango-runtime /mingw64/bin
    export DINOX_LYREBIRD_PATH="$LYREBIRD_PATH"
    bash scripts/update_dist.sh --preflight-runtime-helpers

    echo "==> Source: $PROJECT_ROOT"
    echo "==> Source commit: $(git rev-parse HEAD)"
    echo "==> Windows build type: $BUILD_TYPE (optimization=2, debug=$BUILD_DEBUG)"
    echo "==> Google/libwebrtc runtime: $RUNTIME_ROOT"

    scripts/check-libwebrtc-windows-runtime.sh "$RUNTIME_ROOT"

    echo "==> Running native Google/libwebrtc Windows smokes"
    (
        cd "$RUNTIME_ROOT/bin"
        # Never let an inherited developer override select an older worker with
        # the same C ABI. Every native test must exercise this validated runtime.
        DINOX_WEBRTC_WORKER_PATH="$PWD/dinox-webrtc-worker.exe"
        if command -v cygpath >/dev/null 2>&1; then
            DINOX_WEBRTC_WORKER_PATH="$(cygpath -m "$DINOX_WEBRTC_WORKER_PATH")"
        fi
        export DINOX_WEBRTC_WORKER_PATH
        export DINOX_WEBRTC_IN_PROCESS_TEST_ORACLE=0
        unset DINOX_WEBRTC_VIDEO_CODEC_SMOKE_ONLY
        for smoke in \
            dinox-webrtc-ipc-protocol-smoke.exe \
            dinox-webrtc-video-ring-smoke.exe \
            dinox-webrtc-process-engine-smoke.exe \
            dinox-webrtc-muji-sdp-smoke.exe; do
            "./$smoke"
        done
        # Legacy M150 runtimes have no private hardware provider or these
        # additional test executables. M152's runtime checker requires all of them.
        if [ -f ../FFMPEG-WINDOWS-HARDWARE.json ]; then
            ./dinox-webrtc-windows-codec-provider-smoke.exe
            ./dinox-webrtc-video-codec-smoke.exe
            ./dinox-webrtc-video-codec-smoke.exe --runtime-failure
            for codec in H264 VP9 VP8; do
                DINOX_WEBRTC_VIDEO_CODEC_SMOKE_ONLY="$codec" \
                    ./dinox-webrtc-muji-sdp-smoke.exe
            done
        fi
    )

    echo "==> Configuring the production Google/libwebrtc profile"
    compiler_native_file="$PROJECT_ROOT/build/windows-compiler-native.ini"
    python3 "$PROJECT_ROOT/scripts/windows-compiler-paths.py" \
        --write-native-file "$(cygpath -m "$compiler_native_file")"
    meson setup build --native-file "$compiler_native_file" "${MESON_OPTIONS[@]}"

    meson introspect build --buildoptions > build/windows-build-options.json
    python3 - build/windows-build-options.json "$RUNTIME_ROOT" "$BUILD_TYPE" "$BUILD_DEBUG" <<'PY'
import json
import pathlib
import sys

options = {
    item["name"]: item["value"]
    for item in json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
}
expected = {
    "buildtype": sys.argv[3],
    "optimization": "2",
    "debug": sys.argv[4] == "true",
    "plugin-rtp": "disabled",
    "plugin-google-webrtc": "enabled",
    "google-libwebrtc-wrapper": "enabled",
    "google-libwebrtc-test-oracle": False,
    "google-libwebrtc-tests": False,
    "plugin-omemo": "enabled",
    "plugin-openpgp": "enabled",
    "plugin-ice": "enabled",
    "plugin-http-files": "enabled",
    "plugin-mqtt": "enabled",
    "plugin-notification-sound": "enabled",
    "location-sharing": "disabled",
}
for name, value in expected.items():
    if options.get(name) != value:
        raise SystemExit(
            f"FAIL: Meson option {name}={options.get(name)!r}, expected {value!r}"
        )

configured_runtime = str(options.get("google-libwebrtc-runtime-root", "")).replace("\\", "/")
expected_runtime = sys.argv[2].replace("\\", "/")
if configured_runtime not in {expected_runtime, "C:/msys64" + expected_runtime}:
    raise SystemExit(
        "FAIL: Meson google-libwebrtc-runtime-root="
        f"{configured_runtime!r}, expected {expected_runtime!r}"
    )
PY

    echo "==> Building every DinoX Windows target"
    ninja -C build "${NINJA_ARGS[@]}"
    meson test -C build --no-rebuild --print-errorlogs 'Native GIO stream bindings'

    echo "==> Validating the native Windows backup archive helper"
    meson test -C build --no-rebuild --print-errorlogs \
        'Windows backup archive runtime'

    echo "==> DNSSEC/DANE native TLS, Unicode CA and proxy policy tests"
    meson test -C build --no-rebuild --print-errorlogs --timeout-multiplier 3 --num-processes 1 \
        'DNSSEC signed-zone resolver' 'DNSSEC HTTPS SOCKS5 transport' \
        'DNSSEC HTTP2 SOCKS5 transport' 'DANE certificate verification' \
        'XMPP DANE pre-authentication gate' 'DNSSEC XMPP service discovery' \
        'MQTT DANE before CONNECT' 'MQTT client DNS policy and cancellation'

    echo "==> Login protection, reconnect and account-isolation regressions"
    meson test -C build --no-rebuild --print-errorlogs --timeout-multiplier 3 --num-processes 1 \
        'SASL TLS downgrade protection'
    # Gtk/Adwaita requires an interactive Windows desktop for this widget test.
    # The same executable passes on the desktop but crashes in GTK initialization
    # in the OpenSSH service session. Keep that boundary explicit, not a false pass.
    if [[ "${DINOX_WINDOWS_UI_TESTS:-0}" == "1" ]]; then
        meson test -C build --no-rebuild --print-errorlogs --timeout-multiplier 3 \
            'Login protection UI runtime'
    else
        echo "SKIP: Login protection UI runtime requires an interactive desktop; set DINOX_WINDOWS_UI_TESTS=1 there."
    fi
    meson test -C build --no-rebuild --print-errorlogs --num-processes 1 \
        --test-args="-p /SaslSecurity -p '/SASL channel binding' -p /ReconnectStartup -p /PubSubAudit -p /AvatarProtocolAudit -p /MessageDisplayedSync" \
        'Tests for xmpp-vala'
    meson test -C build --no-rebuild --print-errorlogs --num-processes 1 \
        --test-args='-p /ConnectionManagerAudit' 'Tests for libdino'
    meson test -C build --no-rebuild --print-errorlogs --num-processes 1 \
        --test-args='-p /LegacyBundlePubSub -p /LegacyOwnBundleMaintenance -p /LegacyRegistrationPubSub -p /MultiAccountMessageState' \
        'Tests for omemo'

    echo "==> Strict test build and Google/libwebrtc Windows smokes"
    meson setup --reconfigure build -Dgoogle-libwebrtc-tests=true
    bash scripts/build.sh --strict
    meson test -C build --no-rebuild --print-errorlogs --timeout-multiplier 10 --num-processes 1 \
        google-webrtc-media-foundation-writer-smoke \
        google-webrtc-engine-smoke \
        google-webrtc-signaling-smoke \
        google-webrtc-jingle-engine-smoke \
        google-webrtc-jingle-wire-smoke \
        google-webrtc-jmi-wire-smoke \
        google-webrtc-plugin-capability-smoke \
        google-webrtc-audio-only-smoke
    meson setup --reconfigure build -Dgoogle-libwebrtc-tests=false
    ninja -C build "${NINJA_ARGS[@]}"

    echo "==> Creating and validating a fresh portable dist"
    export DINOX_GOOGLE_WEBRTC_RUNTIME_ROOT="$RUNTIME_ROOT"
    export DINOX_LYREBIRD_PATH="$LYREBIRD_PATH"
    export DINOX_BUILD_DIR=build
    bash scripts/update_dist.sh

    trap - EXIT

    echo
    if command -v cygpath >/dev/null 2>&1; then
        echo "WINDOWS_DIST_READY=$(cygpath -w "$PROJECT_ROOT/dist/dinox.exe")"
    else
        echo "WINDOWS_DIST_READY=$PROJECT_ROOT/dist/dinox.exe"
    fi
}

run_logged_build build_windows_distribution
