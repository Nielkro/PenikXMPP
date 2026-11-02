#!/usr/bin/env bash
set -euo pipefail

# Keep standalone validation on the same native MINGW64 toolchain as the
# canonical builder.  An SSH-launched MSYS shell otherwise puts /usr/bin first,
# which can change PE-tool behaviour compared with the actual build.
if [ -d /mingw64/bin ]; then
    export PATH="/mingw64/bin:/usr/bin:$PATH"
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_BUILD_POSIX="$PROJECT_ROOT/build/"
if command -v cygpath >/dev/null 2>&1; then
    PROJECT_BUILD_WINDOWS="$(cygpath -m "$PROJECT_ROOT/build")/"
else
    PROJECT_BUILD_WINDOWS=""
fi

usage() {
    echo "Usage: $0 [DIST_DIR]"
    echo "       $0 --pango-runtime DIR"
    echo "       $0 --tor-transport-runtime DIR"
    echo "       $0 --self-test"
    echo
    echo "Validates a complete portable DinoX Windows distribution."
    echo "--pango-runtime validates only the pinned four-DLL Pango runtime set."
    echo "--tor-transport-runtime checks packaged Tor/Lyrebird using loopback fixtures only."
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Keep the complete Pango runtime on the validated 1.56.4-3 MSYS2 package.
# Pango 1.57 introduced a color-font selector which its Win32 font map does
# not implement, so current rolling MSYS2 builds fail to resolve VS16 emoji.
# Hash all four DLLs as one set: mixing an older core DLL with newer companion
# DLLs is not ABI-safe because Pango 1.58 companions import new core symbols.
pango_runtime_files=(
    libpango-1.0-0.dll
    libpangocairo-1.0-0.dll
    libpangoft2-1.0-0.dll
    libpangowin32-1.0-0.dll
)
pango_runtime_sha256=(
    1a839a1cac18e55ed51f4beb9afa235137f683b11641be9716490ee52726428a
    eeda1d46baebe2964eaf28c85dbeb53d63a26d6400b0f3ca418e1441532e972f
    4cb74382e624d867f95d2eaf3a021642aea878f1eb6448a65478215e7484611a
    2b31fb7152d134fa08edd7e721a7cde1a24c38674f726f1a1d5eb3e76a35f6d5
)

check_pango_runtime() {
    local runtime_root="$1"
    local index
    local relative
    local expected
    local actual

    if [ ! -d "$runtime_root" ]; then
        fail "Pango runtime directory not found: $runtime_root"
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        fail "sha256sum is required for the Pango runtime gate"
    fi
    for index in "${!pango_runtime_files[@]}"; do
        relative="${pango_runtime_files[$index]}"
        expected="${pango_runtime_sha256[$index]}"
        if [ ! -s "$runtime_root/$relative" ]; then
            fail "required Pango runtime DLL missing or empty: $relative"
        fi
        actual="$(sha256sum "$runtime_root/$relative" | awk '{print $1}')"
        if [ "$actual" != "$expected" ]; then
            fail "unvalidated Pango runtime DLL: $relative has SHA-256 $actual, expected $expected"
        fi
    done
}

validate_helper_pe_structure() (
    local dist_root="$1"
    local relative
    shift
    command -v objdump >/dev/null 2>&1 \
        || fail "objdump is required for the packaged PE structure gate"
    # Native MinGW objdump cannot open absolute Unicode paths. Keep its
    # filenames relative while Windows supplies the Unicode working directory.
    cd "$dist_root" || fail "Windows distribution directory not found: $dist_root"
    for relative in "$@"; do
        if ! objdump -x "$relative" >/dev/null 2>&1; then
            fail "packaged helper has an invalid PE/COFF structure: $relative"
        fi
    done
)

validate_expected_catalog_set() {
    local linguas_file="$1"
    local domain="$2"
    local dist_locale_root="$3"
    local raw
    local lang
    local catalog
    local -a line_languages=()
    local count=0

    [ -s "$linguas_file" ] || fail "LINGUAS file missing or empty: $linguas_file"

    while IFS= read -r raw || [ -n "$raw" ]; do
        raw="${raw//$'\r'/}"
        raw="${raw%%#*}"
        read -r -a line_languages <<< "$raw"
        for lang in "${line_languages[@]}"; do
            case "$lang" in
                *[!A-Za-z0-9_.@-]*)
                    fail "invalid locale '$lang' in $linguas_file"
                    ;;
            esac
            catalog="$dist_locale_root/$lang/LC_MESSAGES/$domain.mo"
            [ -s "$catalog" ] \
                || fail "required translation missing or empty: ${catalog#"$dist_locale_root"/}"
            count=$((count + 1))
        done
    done < "$linguas_file"

    [ "$count" -gt 0 ] || fail "LINGUAS file contains no locales: $linguas_file"
    VALIDATED_CATALOG_SET_COUNT="$count"
}

validate_runtime_catalogs() {
    local dist_locale_root="$1"
    local lang
    local domain
    local catalog
    local count=0
    local -a required_languages=(de ru)
    local -a runtime_domains=(gtk40 glib20 gdk-pixbuf libadwaita)

    for lang in "${required_languages[@]}"; do
        for domain in "${runtime_domains[@]}"; do
            catalog="$dist_locale_root/$lang/LC_MESSAGES/$domain.mo"
            [ -s "$catalog" ] \
                || fail "required GTK runtime translation missing or empty: ${catalog#"$dist_locale_root"/}"
            count=$((count + 1))
        done
    done

    [ "$count" -gt 0 ] || fail "no GTK runtime translations found"
    VALIDATED_RUNTIME_CATALOG_COUNT="$count"
}

extract_translation_digest() {
    local language="$1"
    local output="${2//$'\r'/}"

    sed -nE \
        "s/^DinoX Windows portable translation smoke OK \($language:([0-9a-f]{64})\)$/\1/p" \
        <<< "$output"
}

validate_embedded_utf8_manifest() {
    local executable="$1"
    local marker='<activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>'

    [ -s "$executable" ] || fail "Windows executable missing or empty: $executable"
    grep -aF "$marker" "$executable" >/dev/null \
        || fail "$(basename "$executable") does not embed the UTF-8 process-code-page manifest"
}

write_tor_transport_smoke_config() {
    printf 'DataDirectory "%s"\n' "$1"
    printf 'PidFile "%s"\n' "$2"
    printf 'GeoIPFile "%s"\n' "$3"
    printf 'GeoIPv6File "%s"\n' "$4"
    # DisableNetwork would skip managed transports altogether. Instead, use
    # only literal loopback targets, including replacement directory servers.
    # The fake bridge keys are public test data, never real bridge credentials.
    printf '%s\n' \
        'ClientTransportPlugin obfs4,webtunnel exec .\lyrebird.exe' \
        'UseBridges 1' \
        'UpdateBridgesFromAuthority 0' \
        'UseDefaultFallbackDirs 0' \
        'ClientOnly 1' \
        'SocksPort 0' \
        'ControlPort 0' \
        'RunAsDaemon 0' \
        'Log info stdout' \
        'DirAuthority loopback orport=9 v3ident=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 127.0.0.1:9 BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' \
        'FallbackDir 127.0.0.1:9 orport=9 id=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' \
        'Bridge obfs4 127.0.0.1:9 CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC cert=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA iat-mode=0' \
        'Bridge webtunnel 127.0.0.1:9 DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD url=https://127.0.0.1:9/dinox-fixture ver=0.0.3'
}

tor_transport_smoke_registered() {
    grep -Eq 'Successfully registered transport obfs4([[:space:].]|$)' "$1" \
        && grep -Eq 'Successfully registered transport webtunnel([[:space:].]|$)' "$1"
}

tor_transport_smoke_failed() {
    grep -Ei 'Could not launch managed proxy|Managed proxy .*failed|CreateProcessA\(\) failed|Failed to parse/validate config' "$1" >/dev/null
}

run_tor_transport_runtime_smoke() (
    local source_dist="$1"
    local fixture_root fixture_dist fixture_data fixture_log fixture_config
    local pid_file native_pid="" supervisor_pid="" fixture_path
    local config_native data_native pid_native geoip_native geoip6_native bin_native
    local transport_output fixture_started=0
    local powershell_bin='/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
    command -v cygpath >/dev/null 2>&1 || fail "Tor transport runtime gate requires MSYS2"
    command -v timeout >/dev/null 2>&1 || fail "timeout is required for the Tor transport gate"
    [ -x "$powershell_bin" ] || fail "PowerShell is required for targeted Tor transport cleanup"
    [ -d "$source_dist" ] || fail "Windows distribution directory not found: $source_dist"
    source_dist="$(cd "$source_dist" && pwd)"
    fixture_root="$(mktemp -d "$(dirname "$source_dist")/.dinox-tor-transport.XXXXXX")"
    fixture_dist="$fixture_root/Игорь Петров/DinoX Portable"
    fixture_data="$fixture_root/Игорь Петров/Tor Данные"
    fixture_config="$fixture_root/Игорь Петров/Tor Конфигурация/torrc"
    fixture_log="$fixture_root/tor.log"
    pid_file="$fixture_data/tor.pid"
    cleanup_tor_transport_smoke() {
        local exit_status="$?"
        trap - EXIT
        # Stop further launches first, but do not assume that killing the
        # MSYS timeout supervisor also stopped native Tor or its transport.
        if [ -n "$supervisor_pid" ] && kill -0 "$supervisor_pid" 2>/dev/null; then
            kill "$supervisor_pid" 2>/dev/null || true
            for _cleanup_attempt in {1..30}; do
                kill -0 "$supervisor_pid" 2>/dev/null || break
                sleep 0.1
            done
            kill -KILL "$supervisor_pid" 2>/dev/null || true
        fi
        if [ -n "$supervisor_pid" ]; then
            wait "$supervisor_pid" 2>/dev/null || true
        fi
        if [ "$fixture_started" -eq 1 ]; then
            if [ -s "$pid_file" ]; then
                native_pid="$(tr -d '\r\n' < "$pid_file")"
                [[ "$native_pid" =~ ^[1-9][0-9]*$ ]] || native_pid=""
            fi
            # Inspect even after Tor/supervisor exit: an orphaned Lyrebird
            # still belongs to this fixture by its exact executable path.
            # Never kill by executable name alone or trust a stale PID alone.
            if ! timeout -k 2s 12s env MSYS2_ARG_CONV_EXCL='*' \
                    MSYS2_ENV_CONV_EXCL='DINOX_TOR_SMOKE_BIN;DINOX_TOR_SMOKE_CONFIG;DINOX_TOR_SMOKE_PID' \
                    DINOX_TOR_SMOKE_BIN="$bin_native" \
                    DINOX_TOR_SMOKE_CONFIG="$config_native" \
                    DINOX_TOR_SMOKE_PID="$native_pid" \
                    "$powershell_bin" -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
$torExe = [IO.Path]::GetFullPath((Join-Path $env:DINOX_TOR_SMOKE_BIN "tor.exe"))
$ptExe = [IO.Path]::GetFullPath((Join-Path $env:DINOX_TOR_SMOKE_BIN "lyrebird.exe"))
$configPath = [IO.Path]::GetFullPath($env:DINOX_TOR_SMOKE_CONFIG)
$pathComparer = [StringComparer]::OrdinalIgnoreCase
function Get-FixtureProcesses {
    Get-CimInstance Win32_Process -Filter "Name = '"'"'tor.exe'"'"' OR Name = '"'"'lyrebird.exe'"'"'" |
        Where-Object {
            if ([string]::IsNullOrEmpty($_.ExecutablePath)) {
                throw "Cannot verify a Tor/Lyrebird process path; refusing to report cleanup success."
            }
            $pathComparer.Equals([string]$_.ExecutablePath, $torExe) -or
            $pathComparer.Equals([string]$_.ExecutablePath, $ptExe)
        } | Sort-Object @{Expression = { if ($_.Name -ieq "tor.exe") { 0 } else { 1 } }}
}
try {
    # Stop Tor before its children, then rescan in case it spawned a transport
    # after the first snapshot. The second pass also catches orphaned helpers.
    for ($pass = 0; $pass -lt 2; $pass++) {
        foreach ($candidate in @(Get-FixtureProcesses)) {
            if ($pathComparer.Equals([string]$candidate.ExecutablePath, $torExe)) {
                if (($env:DINOX_TOR_SMOKE_PID -and
                     [string]$candidate.ProcessId -ne $env:DINOX_TOR_SMOKE_PID) -or
                    ([string]$candidate.CommandLine).Replace("/", "\").IndexOf(
                        $configPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    throw "Fixture Tor PID/config identity mismatch; refusing to kill it."
                }
            }
            $process = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
            if ($null -eq $process) { continue }
            try {
                # Hold a native handle and recheck the path before termination
                # so a reused PID cannot select an unrelated process.
                $null = $process.Handle
                if ($process.HasExited) { continue }
                if (-not $pathComparer.Equals($process.MainModule.FileName,
                                               [string]$candidate.ExecutablePath)) {
                    throw "Fixture process identity changed; refusing to kill it."
                }
                $process.Kill()
                if (-not $process.WaitForExit(2000)) {
                    throw "Fixture process did not stop before the cleanup deadline."
                }
            } finally { $process.Dispose() }
        }
    }
    if (@(Get-FixtureProcesses).Count -ne 0) {
        throw "Fixture Tor/Lyrebird process remains after cleanup."
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
exit 0
'; then
                echo "FAIL: could not confirm Tor/Lyrebird cleanup; retained fixture: $fixture_root" >&2
                exit 1
            fi
        fi
        cd "$source_dist"
        rm -rf -- "$fixture_root"
        exit "$exit_status"
    }
    trap cleanup_tor_transport_smoke EXIT
    mkdir -p -- "$fixture_dist" "$fixture_data" "$(dirname "$fixture_config")"
    # Hard links preserve the portable DLL closure without copying its bytes.
    cp -al -- "$source_dist"/. "$fixture_dist"/
    config_native="$(cygpath -m "$fixture_config")"
    data_native="$(cygpath -m "$fixture_data")"
    pid_native="$(cygpath -m "$pid_file")"
    geoip_native="$(cygpath -m "$fixture_dist/share/tor/geoip")"
    geoip6_native="$(cygpath -m "$fixture_dist/share/tor/geoip6")"
    bin_native="$(cygpath -m "$fixture_dist/bin")"
    fixture_path="$fixture_dist:$fixture_dist/bin:$fixture_dist/plugins:/c/Windows/System32:/c/Windows"
    validate_embedded_utf8_manifest "$fixture_dist/bin/tor.exe"
    cd "$fixture_dist/bin"
    fixture_started=1
    transport_output="$(timeout -k 2s 10s env PATH="$fixture_path" ./lyrebird.exe --version 2>&1)" \
        || fail "packaged Unicode-path Lyrebird could not start: $transport_output"
    [[ "${transport_output//$'\r'/}" == lyrebird\ 0.8.1* ]] \
        || fail "unexpected Lyrebird version: $transport_output"
    write_tor_transport_smoke_config "$data_native" "$pid_native" \
        "$geoip_native" "$geoip6_native" > "$fixture_config"
    if ! timeout -k 2s 10s env PATH="$fixture_path" ./tor.exe \
            --defaults-torrc NUL -f "$config_native" --verify-config > "$fixture_log" 2>&1; then
        fail "packaged Tor rejected the loopback transport fixture: $(tr '\r\n' ' ' < "$fixture_log")"
    fi
    timeout -k 3s 20s env \
        -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
        -u http_proxy -u https_proxy -u all_proxy -u TOR_PT_PROXY \
        PATH="$fixture_path" ./tor.exe --defaults-torrc NUL -f "$config_native" \
        > "$fixture_log" 2>&1 &
    supervisor_pid="$!"
    for _attempt in {1..200}; do
        if tor_transport_smoke_failed "$fixture_log"; then
            fail "managed transport failed: $(tr '\r\n' ' ' < "$fixture_log")"
        fi
        if tor_transport_smoke_registered "$fixture_log" \
                && [ -s "$fixture_data/state" ] && [ -s "$pid_file" ]; then
            echo "OK: packaged Unicode-path Tor registered obfs4 and WebTunnel (loopback fixtures only)"
            exit 0
        fi
        if ! kill -0 "$supervisor_pid" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    fail "Tor did not register both transports before its deadline: $(tr '\r\n' ' ' < "$fixture_log")"
)

expect_catalog_validation_rejected() {
    local label="$1"
    shift

    if ("$@" >/dev/null 2>&1); then
        echo "Self-test failed: $label was accepted" >&2
        return 1
    fi
}

run_self_test() (
    local tmpdir
    local lang
    local domain
    local fixture_digest
    local parsed_digest

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    mkdir -p \
        "$tmpdir/Quellen mit Leerzeichen" \
        "$tmpdir/Пакет с пробелом/locale/de/LC_MESSAGES" \
        "$tmpdir/Пакет с пробелом/locale/ru/LC_MESSAGES"
    printf '%s\n' '# fixture locales' 'de ru' \
        > "$tmpdir/Quellen mit Leerzeichen/LINGUAS"
    printf '%s\n' 'de fixture' \
        > "$tmpdir/Пакет с пробелом/locale/de/LC_MESSAGES/dino.mo"
    printf '%s\n' 'ru fixture' \
        > "$tmpdir/Пакет с пробелом/locale/ru/LC_MESSAGES/dino.mo"
    validate_expected_catalog_set \
        "$tmpdir/Quellen mit Leerzeichen/LINGUAS" \
        dino \
        "$tmpdir/Пакет с пробелом/locale"
    [ "$VALIDATED_CATALOG_SET_COUNT" -eq 2 ]
    rm "$tmpdir/Пакет с пробелом/locale/ru/LC_MESSAGES/dino.mo"
    expect_catalog_validation_rejected \
        "missing expected DinoX translation" \
        validate_expected_catalog_set \
        "$tmpdir/Quellen mit Leerzeichen/LINGUAS" \
        dino \
        "$tmpdir/Пакет с пробелом/locale"

    for lang in de ru; do
        mkdir -p "$tmpdir/Пакет с пробелом/share/locale/$lang/LC_MESSAGES"
        for domain in gtk40 glib20 gdk-pixbuf libadwaita; do
            printf '%s\n' "$lang $domain fixture" \
                > "$tmpdir/Пакет с пробелом/share/locale/$lang/LC_MESSAGES/$domain.mo"
        done
    done
    validate_runtime_catalogs "$tmpdir/Пакет с пробелом/share/locale"
    [ "$VALIDATED_RUNTIME_CATALOG_COUNT" -eq 8 ]
    rm "$tmpdir/Пакет с пробелом/share/locale/ru/LC_MESSAGES/gtk40.mo"
    expect_catalog_validation_rejected \
        "missing required GTK runtime translation" \
        validate_runtime_catalogs \
        "$tmpdir/Пакет с пробелом/share/locale"

    fixture_digest="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    parsed_digest="$(
        extract_translation_digest \
            de \
            "$(printf 'DinoX Windows portable translation smoke OK (de:%s)\r\nDinoX Windows portable runtime smoke OK (9 plugins)\r\n' "$fixture_digest")"
    )"
    [ "$parsed_digest" = "$fixture_digest" ] \
        || {
            echo "Self-test failed: CRLF translation smoke digest was not parsed" >&2
            return 1
        }

    printf '\0%s\0' \
        '<activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>' \
        > "$tmpdir/dinox-utf8-manifest.exe"
    validate_embedded_utf8_manifest "$tmpdir/dinox-utf8-manifest.exe"
    printf '%s\n' 'no process manifest' > "$tmpdir/dinox-no-manifest.exe"
    expect_catalog_validation_rejected \
        "missing embedded UTF-8 process manifest" \
        validate_embedded_utf8_manifest \
        "$tmpdir/dinox-no-manifest.exe"

    mkdir -p "$tmpdir/Пакет с пробелом/bin"
    printf '%s\n' 'valid PE fixture' > "$tmpdir/Пакет с пробелом/bin/valid.exe"
    printf '%s\n' 'broken PE fixture' > "$tmpdir/Пакет с пробелом/bin/broken.exe"
    # Model MinGW's path boundary; actual Windows probes use real PE files.
    objdump() {
        [ "$#" -eq 2 ] && [ "$1" = -x ] \
            && [ "$PWD" = "$tmpdir/Пакет с пробелом" ] \
            && [[ "$2" != /* && "$2" != [A-Za-z]:* ]] \
            && grep -Fx 'valid PE fixture' "$2" >/dev/null
    }
    validate_helper_pe_structure "$tmpdir/Пакет с пробелом" bin/valid.exe
    expect_catalog_validation_rejected \
        "invalid PE structure" \
        validate_helper_pe_structure "$tmpdir/Пакет с пробелом" bin/broken.exe
    expect_catalog_validation_rejected \
        "missing PE helper" \
        validate_helper_pe_structure "$tmpdir/Пакет с пробелом" bin/missing.exe
    unset -f objdump

    write_tor_transport_smoke_config 'C:/Профиль/Tor Data' 'C:/Профиль/tor.pid' \
        'C:/DinoX/geoip' 'C:/DinoX/geoip6' > "$tmpdir/torrc"
    grep -Fx 'ClientTransportPlugin obfs4,webtunnel exec .\lyrebird.exe' "$tmpdir/torrc" >/dev/null
    ! grep -F 'DisableNetwork 1' "$tmpdir/torrc" >/dev/null
    [ "$(grep -Ec '^(Bridge|FallbackDir|DirAuthority) .*127\.0\.0\.1:9' "$tmpdir/torrc")" -eq 4 ]
    printf '%s\n' '[info] Successfully registered transport obfs4' > "$tmpdir/tor.log"
    ! tor_transport_smoke_registered "$tmpdir/tor.log"
    printf '%s\n' '[info] Successfully registered transport webtunnel' >> "$tmpdir/tor.log"
    tor_transport_smoke_registered "$tmpdir/tor.log"
    ! tor_transport_smoke_failed "$tmpdir/tor.log"
    printf '%s\n' '[warn] Managed proxy at ./lyrebird.exe failed at launch.' >> "$tmpdir/tor.log"
    tor_transport_smoke_failed "$tmpdir/tor.log"

    echo "Self-test OK"
)

case "${1:-}" in
    -h|--help)
        [ "$#" -eq 1 ] || { usage >&2; exit 2; }
        usage
        exit 0
        ;;
    --pango-runtime)
        [ "$#" -eq 2 ] || { usage >&2; exit 2; }
        check_pango_runtime "$2"
        echo "OK: validated Pango 1.56.4-3 runtime set"
        exit 0
        ;;
    --self-test)
        [ "$#" -eq 1 ] || { usage >&2; exit 2; }
        run_self_test
        exit 0
        ;;
    --tor-transport-runtime)
        [ "$#" -eq 2 ] || { usage >&2; exit 2; }
        run_tor_transport_runtime_smoke "$2"
        exit 0
        ;;
esac
if [ "$#" -gt 1 ]; then
    usage >&2
    exit 2
fi

DIST_ROOT="${1:-$PROJECT_ROOT/dist}"
[ -d "$DIST_ROOT" ] || fail "Windows distribution directory not found: $DIST_ROOT"
DIST_ROOT="$(cd "$DIST_ROOT" && pwd)"

required_files=(
    dinox.exe
    build-info.txt
    libdino-0.dll
    libxmpp-vala-0.dll
    libqlite-0.dll
    libcrypto-vala-0.dll
    libpango-1.0-0.dll
    libpangocairo-1.0-0.dll
    libpangoft2-1.0-0.dll
    libpangowin32-1.0-0.dll
    dinox-google-webrtc.dll
    dinox-webrtc-worker.exe
    dinox-vision-worker.exe
    dinox-vision-models/selfie_segmenter_landscape-v1.tflite
    dinox-vision-models/blaze_face_short_range-v1.tflite
    dinox-vision-runtime-manifest.json
    dinox-vision-SHA256SUMS
    plugins/google-webrtc.dll
    plugins/http-files.dll
    plugins/ice.dll
    plugins/notification-sound.dll
    plugins/omemo.dll
    plugins/openpgp.dll
    plugins/mqtt.dll
    plugins/bot-features.dll
    plugins/libtor-manager.dll
    bin/gpg.exe
    bin/gpg-agent.exe
    bin/gpgconf.exe
    bin/gpg-connect-agent.exe
    bin/dirmngr.exe
    bin/pinentry-w32.exe
    bin/gpgme-w32spawn.exe
    bin/openssl.exe
    bin/dinox-backup-tar.exe
    bin/tor.exe
    bin/lyrebird.exe
    gpgme-w32spawn.exe
    gspawn-win64-helper.exe
    gspawn-win64-helper-console.exe
    ssl/certs/ca-bundle.crt
    libunbound-8.dll
    share/glib-2.0/schemas/gschemas.compiled
    share/icons/hicolor/48x48/apps/im.dinox.dinox.png
    share/icons/hicolor/scalable/actions/check-plain-symbolic.svg
    share/icons/hicolor/scalable/actions/dino-emoticon-add-symbolic.svg
    share/icons/hicolor/scalable/actions/sync-synchronizing-symbolic.svg
    share/icons/Adwaita/symbolic/actions/mail-reply-sender-symbolic.svg
    share/icons/Adwaita/symbolic/places/user-trash-symbolic.svg
    share/icons/hicolor/scalable/status/dino-security-high-symbolic.svg
    etc/fonts/fonts.conf
    etc/fonts/local.conf
    lib/gio/modules/giomodule.cache
    lib/gio/modules/libgiognutls.dll
    lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
    lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-png.dll
    lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-jpeg.dll
    lib/gstreamer-1.0/libgstapp.dll
    lib/gstreamer-1.0/libgstcoreelements.dll
    lib/gstreamer-1.0/libgstisomp4.dll
    lib/gstreamer-1.0/libgstlibav.dll
    lib/gstreamer-1.0/libgstplayback.dll
    lib/gstreamer-1.0/libgstvideoconvertscale.dll
    lib/gstreamer-1.0/libgstvideoparsersbad.dll
    libgstrtp-1.0-0.dll
    share/licenses/dinox/google-libwebrtc/LICENSE
    share/licenses/dinox/google-libwebrtc/LICENSE.md
    share/licenses/dinox/google-libwebrtc/PATENTS
    share/licenses/dinox/google-libwebrtc/manifest.json
    share/licenses/dinox/dinox/LICENSE
    share/licenses/dinox/dinox/NOTICE
    share/licenses/dinox/dinox/AUTHORS
    share/licenses/dinox/WINDOWS-PE-INVENTORY.tsv
    share/licenses/dinox/WINDOWS-ASSET-INVENTORY.tsv
    share/licenses/dinox/WINDOWS-STATIC-COMPONENTS.tsv
    share/licenses/dinox/WINDOWS-LICENSE-FILES.tsv
    share/licenses/dinox/THIRD_PARTY_NOTICES.md
)

for relative in "${required_files[@]}"; do
    [ -s "$DIST_ROOT/$relative" ] || fail "required Windows runtime file missing or empty: $relative"
done

validate_embedded_utf8_manifest "$DIST_ROOT/dinox.exe"
validate_embedded_utf8_manifest "$DIST_ROOT/bin/openssl.exe"
validate_embedded_utf8_manifest "$DIST_ROOT/bin/dinox-backup-tar.exe"
validate_embedded_utf8_manifest "$DIST_ROOT/bin/tor.exe"
validate_helper_pe_structure "$DIST_ROOT" \
    bin/openssl.exe bin/tor.exe bin/dinox-backup-tar.exe

DINOX_CATALOG_COUNT=0
validate_expected_catalog_set \
    "$PROJECT_ROOT/main/po/LINGUAS" \
    dino \
    "$DIST_ROOT/locale"
DINOX_CATALOG_COUNT=$((DINOX_CATALOG_COUNT + VALIDATED_CATALOG_SET_COUNT))
validate_expected_catalog_set \
    "$PROJECT_ROOT/plugins/omemo/po/LINGUAS" \
    dino-omemo \
    "$DIST_ROOT/locale"
DINOX_CATALOG_COUNT=$((DINOX_CATALOG_COUNT + VALIDATED_CATALOG_SET_COUNT))
validate_expected_catalog_set \
    "$PROJECT_ROOT/plugins/openpgp/po/LINGUAS" \
    dino-openpgp \
    "$DIST_ROOT/locale"
DINOX_CATALOG_COUNT=$((DINOX_CATALOG_COUNT + VALIDATED_CATALOG_SET_COUNT))
[ "$DINOX_CATALOG_COUNT" -gt 0 ] || fail "no DinoX translations found"
validate_runtime_catalogs "$DIST_ROOT/share/locale"

check_pango_runtime "$DIST_ROOT"

pixbuf_cache="$DIST_ROOT/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
pixbuf_loader_dir="$DIST_ROOT/lib/gdk-pixbuf-2.0/2.10.0/loaders"
pixbuf_binary_count="$(
    find "$pixbuf_loader_dir" -maxdepth 1 -type f -iname '*.dll' | wc -l
)"
pixbuf_cache_count="$(
    grep -Ec '^"@DINOX_GDK_PIXBUF_MODULEDIR@/[^"]+[.][dD][lL][lL]"$' \
        "$pixbuf_cache" || true
)"
[ "$pixbuf_binary_count" -gt 0 ] \
    || fail "portable dist has no GdkPixbuf loader DLLs"
[ "$pixbuf_cache_count" -eq "$pixbuf_binary_count" ] \
    || fail "pixbuf cache does not map every loader DLL to the portable marker"
python3 - "$pixbuf_cache" "$pixbuf_loader_dir" <<'PY'
import collections
import pathlib
import re
import sys

cache_path = pathlib.Path(sys.argv[1])
loader_dir = pathlib.Path(sys.argv[2])
expected = collections.Counter(
    item.name.casefold()
    for item in loader_dir.iterdir()
    if item.is_file() and item.suffix.casefold() == ".dll"
)
observed = collections.Counter()
pattern = re.compile(
    r'^"@DINOX_GDK_PIXBUF_MODULEDIR@/([^"]+[.]dll)"$',
    flags=re.IGNORECASE,
)
for line in cache_path.read_text(encoding="utf-8").splitlines():
    match = pattern.fullmatch(line)
    if match:
        observed[match.group(1).casefold()] += 1
if observed != expected:
    missing = sorted((expected - observed).elements())
    extra = sorted((observed - expected).elements())
    raise SystemExit(
        "FAIL: pixbuf cache loader names differ from packaged DLLs "
        f"(missing={missing}, extra_or_duplicate={extra})"
    )
PY
if grep -Ei '^"[^"]+[.]dll"$' "$pixbuf_cache" \
        | grep -Fv '"@DINOX_GDK_PIXBUF_MODULEDIR@/' >/dev/null; then
    fail "pixbuf cache contains a loader path without the portable marker"
fi
if grep -E '([A-Za-z]:[/\\]|/mingw64/|/home/[^/]+/)' "$pixbuf_cache" >/dev/null; then
    fail "pixbuf loader cache contains a build-machine path"
fi
if find "$DIST_ROOT/lib/gdk-pixbuf-2.0" -type f \
        \( -iname 'io-wmf.dll' -o -iname '*.dll.a' -o -iname '*.a' \) \
        -print -quit | grep -q .; then
    fail "GDK-Pixbuf runtime contains WMF or build-only import libraries"
fi
if find "$DIST_ROOT" -maxdepth 1 -type f \
        \( -iname 'libwmf-*.dll' -o -iname 'libwmflite-*.dll' \) \
        -print -quit | grep -q .; then
    fail "unused libwmf runtime is forbidden in the portable Windows package"
fi

license_dist_root="$DIST_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    license_dist_root="$(cygpath -m "$DIST_ROOT")"
fi
python3 "$PROJECT_ROOT/scripts/windows-license-inventory.py" verify \
    --dist "$license_dist_root"
python3 "$PROJECT_ROOT/scripts/check-vision-runtime.py" \
    --base "$license_dist_root" --platform windows

# Windows includes the current working directory in native DLL lookup.  Run
# every executable and ldd probe from the package root so a loose DLL beside
# the source checkout cannot hide a missing file in dist/.
cd "$DIST_ROOT"

if [ -e "$DIST_ROOT/plugins/rtp.dll" ]; then
    fail "legacy RTP call plugin is present: plugins/rtp.dll"
fi

shopt -s nullglob nocaseglob
for stale in \
    "$DIST_ROOT"/libgstsdp*.dll \
    "$DIST_ROOT"/libgstwebrtc*.dll \
    "$DIST_ROOT"/libwebrtc-audio-processing*.dll; do
    fail "legacy live-call runtime is present in dist root: $(basename "$stale")"
done
shopt -u nullglob nocaseglob

# GStreamer's ISO-MP4 module imports the libgstrtp core library for RTP hint
# tracks even when no RTP call modules are packaged.  It is the one permitted
# importer.  Checking the complete PE set prevents a differently named plugin
# from silently turning this narrow container dependency into a fallback stack.
shopt -s nullglob nocaseglob
for rtp_core in "$DIST_ROOT"/libgstrtp*.dll; do
    if [ "$(basename "$rtp_core")" != "libgstrtp-1.0-0.dll" ]; then
        fail "unexpected GStreamer RTP core variant is present: $(basename "$rtp_core")"
    fi
done
shopt -u nullglob nocaseglob

rtp_importers=()
while IFS= read -r -d '' artifact; do
    imports="$(objdump -p "$artifact" 2>/dev/null || true)"
    if grep -Fi 'DLL Name: libgstrtp-1.0-0.dll' <<< "$imports" >/dev/null; then
        rtp_importers+=("${artifact#./}")
    fi
done < <(find . -type f \( -iname '*.exe' -o -iname '*.dll' \) -print0)
if [ "${#rtp_importers[@]}" -ne 1 ] \
        || [ "${rtp_importers[0]:-}" != "lib/gstreamer-1.0/libgstisomp4.dll" ]; then
    printf 'Unexpected libgstrtp importers:\n' >&2
    printf '  %s\n' "${rtp_importers[@]:-none}" >&2
    fail "only the packaged ISO-MP4 module may import libgstrtp"
fi

live_call_plugin="$(find "$DIST_ROOT/lib/gstreamer-1.0" -maxdepth 1 -type f \
        \( -iname '*rtp*.dll' -o -iname '*srtp*.dll' -o -iname '*dtls*.dll' \
           -o -iname '*webrtc*.dll' -o -iname '*nice*.dll' \) -print -quit)"
if [ -n "$live_call_plugin" ]; then
    fail "legacy GStreamer live-call plugin is present"
fi

backup_file="$(find "$DIST_ROOT" -type f \
        \( -iname '*.pre-*' -o -iname '*.pref-*' -o -iname '*.old' -o -iname '*.bak' \) \
        -print -quit)"
if [ -n "$backup_file" ]; then
    fail "backup/test files are present in the Windows distribution"
fi

python3 - "$DIST_ROOT/share/licenses/dinox/google-libwebrtc/manifest.json" "$DIST_ROOT" <<'PY'
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
if milestone not in pins:
    raise SystemExit("FAIL: unsupported Google/libwebrtc milestone")
expected = {
    "webrtc_milestone": milestone,
    "webrtc_branch": pins[milestone][0],
    "webrtc_commit": pins[milestone][1],
    "target_os": "win",
    "target_cpu": "x64",
    "artifact_abi": "dinox-libwebrtc-runtime-v2",
    "ipc_protocol_version": 10,
    "video_ring_version": 6,
    "wrapper_abi": 40,
}
for key, value in expected.items():
    if manifest.get(key) != value:
        raise SystemExit(
            f"FAIL: packaged libwebrtc manifest {key}={manifest.get(key)!r}, expected {value!r}"
        )
root = pathlib.Path(sys.argv[2])
vision = json.loads((root / "dinox-vision-runtime-manifest.json").read_text(encoding="utf-8"))
if manifest.get("vision_runtime") != {
    "manifest": "bin/dinox-vision-runtime-manifest.json", "payload_id": vision["payload_id"],
}:
    raise SystemExit("FAIL: packaged libwebrtc manifest has no matched Windows vision package identity")
if milestone == 152:
    root = pathlib.Path(sys.argv[2])
    for relative in (
        "avcodec-dinox-hw-62.dll", "avutil-dinox-hw-60.dll",
        "share/licenses/dinox/google-libwebrtc/WEBRTC-CODECS.json",
        "share/licenses/dinox/google-libwebrtc/WEBRTC-GN-ARGS.gn",
        "share/licenses/dinox/google-libwebrtc/FFMPEG-LICENSE",
        "share/licenses/dinox/google-libwebrtc/FFMPEG-WINDOWS-HARDWARE.json",
        "share/licenses/dinox/google-libwebrtc/CODEC-SOURCES.md",
        "share/licenses/dinox/google-libwebrtc/sources/ffmpeg-mf-dynamic-bitrate.patch",
    ):
        path = root / relative
        if not path.is_file() or path.stat().st_size == 0:
            raise SystemExit(f"FAIL: packaged M152 hardware-codec file missing: {relative}")
    sources = (root / "share/licenses/dinox/google-libwebrtc/CODEC-SOURCES.md").read_text(encoding="utf-8")
    for digest in (
        "2b17c14cc13b4b661c4a2be9b25c26240c97cec4a1c938196ed81dc9fd24278c",
        "464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c",
    ):
        if digest not in sources:
            raise SystemExit("FAIL: packaged M152 source reference hash missing")
PY

if strings "plugins/google-webrtc.dll" \
        | grep -F 'System ffmpeg was not found' >/dev/null; then
    fail "Windows google-webrtc.dll contains the Linux system-FFmpeg path"
fi

portable_path="$DIST_ROOT:$DIST_ROOT/bin:$DIST_ROOT/plugins:/c/Windows/System32:/c/Windows"
version_commands=(
    "bin/gpg.exe:--version"
    "bin/gpg-agent.exe:--version"
    "bin/gpgconf.exe:--version"
    "bin/gpg-connect-agent.exe:--version"
    "bin/dirmngr.exe:--version"
    "bin/pinentry-w32.exe:--version"
    "bin/openssl.exe:version"
    "bin/dinox-backup-tar.exe:--version"
    "bin/tor.exe:--version"
    "bin/lyrebird.exe:--version"
)
for entry in "${version_commands[@]}"; do
    relative="${entry%%:*}"
    argument="${entry#*:}"
    if ! env PATH="$portable_path" "./$relative" "$argument" >/dev/null 2>&1; then
        fail "packaged helper is not executable: $relative $argument"
    fi
done

command -v timeout >/dev/null 2>&1 \
    || fail "timeout is required for the packaged GnuPG lifecycle gate"
gnupg_tmp="$(mktemp -d)"
gnupg_home="$gnupg_tmp/gnupg"
mkdir -p "$gnupg_home"
# MSYS2 on a Windows filesystem may reject POSIX mode changes even though the
# directory is private to the current user. GnuPG still applies native ACLs.
chmod 700 "$gnupg_home" 2>/dev/null || true
cleanup_gnupg_smoke() {
    timeout 15s env PATH="$portable_path" GNUPGHOME="$gnupg_home" \
        "./bin/gpgconf.exe" --homedir "$gnupg_home" --kill all \
        >/dev/null 2>&1 || true
    rm -rf "$gnupg_tmp"
}
trap cleanup_gnupg_smoke EXIT

if ! timeout 15s env PATH="$portable_path" GNUPGHOME="$gnupg_home" \
        "./bin/gpgconf.exe" --homedir "$gnupg_home" --launch gpg-agent \
        >/dev/null 2>&1; then
    fail "packaged gpg-agent could not be started through gpgconf"
fi
if ! timeout 15s env PATH="$portable_path" GNUPGHOME="$gnupg_home" \
        "./bin/gpgconf.exe" --homedir "$gnupg_home" --launch dirmngr \
        >/dev/null 2>&1; then
    fail "packaged dirmngr could not be started through gpgconf"
fi
dirmngr_socket="$(timeout 15s env PATH="$portable_path" GNUPGHOME="$gnupg_home" \
    "./bin/gpgconf.exe" --homedir "$gnupg_home" \
    --list-dirs dirmngr-socket 2>/dev/null)" \
    || fail "packaged gpgconf did not report the isolated dirmngr socket"
dirmngr_socket="${dirmngr_socket#dirmngr-socket:}"
dirmngr_socket="${dirmngr_socket//%3a/:}"
dirmngr_socket="${dirmngr_socket//%3A/:}"
[ -n "$dirmngr_socket" ] || fail "packaged dirmngr socket path is empty"
dirmngr_reply="$(timeout 15s env PATH="$portable_path" GNUPGHOME="$gnupg_home" \
    "./bin/gpg-connect-agent.exe" --raw-socket "$dirmngr_socket" \
    "GETINFO version" </dev/null 2>/dev/null)" \
    || fail "packaged dirmngr did not answer through gpg-connect-agent"
dirmngr_reply="${dirmngr_reply//$'\r'/}"
if ! grep -Eq '^D [^[:space:]]+' <<< "$dirmngr_reply" \
        || ! grep -Fx 'OK' <<< "$dirmngr_reply" >/dev/null; then
    fail "packaged dirmngr did not answer through gpg-connect-agent"
fi
if ! timeout 15s env PATH="$portable_path" GNUPGHOME="$gnupg_home" \
        "./bin/gpgconf.exe" --homedir "$gnupg_home" --kill all \
        >/dev/null 2>&1; then
    fail "packaged GnuPG helpers could not be stopped through gpgconf"
fi
trap - EXIT
rm -rf "$gnupg_tmp"

# VERSION is the canonical release version.  Parsing the complete project()
# line is unsafe because its later meson_version field can be captured instead.
expected_version="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION" 2>/dev/null \
    || true)"
[[ "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    || fail "could not read the expected DinoX version"
version_output="$(env PATH="$portable_path" ./dinox.exe --version 2>&1 \
    | tr -d '\r')" \
    || fail "packaged dinox.exe --version failed"
[ "$version_output" = "DinoX $expected_version" ] \
    || fail "unexpected dinox.exe --version output: $version_output"

runtime_smoke_output="$(env \
    -u GTLS_SYSTEM_CA_FILE \
    -u SSL_CERT_FILE \
    -u SSL_CERT_DIR \
    PATH="$portable_path" \
    ./dinox.exe --runtime-smoke 2>&1)" \
    || fail "packaged dinox.exe --runtime-smoke failed: $runtime_smoke_output"
runtime_smoke_output="${runtime_smoke_output//$'\r'/}"
case "$runtime_smoke_output" in
    *"DinoX Windows portable runtime smoke OK"*) ;;
    *) fail "unexpected dinox.exe --runtime-smoke output: $runtime_smoke_output" ;;
esac

de_translation_digest=""
ru_translation_digest=""
for runtime_smoke_language in de ru; do
    runtime_smoke_output="$(env \
        -u LC_ALL \
        -u LC_MESSAGES \
        -u LANGUAGE \
        -u LANG \
        -u GTLS_SYSTEM_CA_FILE \
        -u SSL_CERT_FILE \
        -u SSL_CERT_DIR \
        PATH="$portable_path" \
        DINOX_RUNTIME_SMOKE_LANGUAGE="$runtime_smoke_language" \
        ./dinox.exe --runtime-smoke 2>&1)" \
        || fail "packaged $runtime_smoke_language translation smoke failed: $runtime_smoke_output"
    runtime_smoke_output="${runtime_smoke_output//$'\r'/}"
    translation_digest="$(
        extract_translation_digest "$runtime_smoke_language" "$runtime_smoke_output"
    )"
    [[ "$translation_digest" =~ ^[0-9a-f]{64}$ ]] \
        || fail "packaged $runtime_smoke_language translation was not applied: $runtime_smoke_output"
    if [ "$runtime_smoke_language" = "de" ]; then
        de_translation_digest="$translation_digest"
    else
        ru_translation_digest="$translation_digest"
    fi
    case "$runtime_smoke_output" in
        *"DinoX Windows portable runtime smoke OK"*) ;;
        *)
            fail "unexpected $runtime_smoke_language translation smoke output: $runtime_smoke_output"
            ;;
    esac
done
[ "$de_translation_digest" != "$ru_translation_digest" ] \
    || fail "packaged German and Russian translation smokes returned the same text"

# Run the complete application smoke through both a Unicode executable path
# and Unicode user-data/cache paths.  Hard links keep this gate fast and avoid
# duplicating the large portable runtime while still making argv[0], locale,
# plugin, pixbuf and GStreamer paths genuinely non-ASCII.
run_unicode_path_runtime_smoke() (
    local unicode_root
    local unicode_dist
    local unicode_home
    local unicode_data
    local unicode_config
    local unicode_cache
    local unicode_home_native
    local unicode_data_native
    local unicode_config_native
    local unicode_cache_native
    local unicode_path
    local unicode_output
    local translation_digest
    local unicode_openssl_root
    local unicode_openssl_input
    local unicode_openssl_cipher
    local unicode_openssl_output
    local unicode_openssl_input_native
    local unicode_openssl_cipher_native
    local unicode_openssl_output_native

    unicode_root="$(mktemp -d "$(dirname "$DIST_ROOT")/.dinox-unicode-runtime.XXXXXX")"
    trap '
        rm -rf -- "$unicode_root"
    ' EXIT
    unicode_dist="$unicode_root/Игорь Петров/DinoX Portable"
    unicode_home="$unicode_root/Игорь Петров/Профиль DinoX"
    unicode_data="$unicode_root/Игорь Петров/Данные DinoX"
    unicode_config="$unicode_root/Игорь Петров/Настройки DinoX"
    unicode_cache="$unicode_root/Игорь Петров/Кэш DinoX"
    mkdir -p -- \
        "$unicode_dist" "$unicode_home" "$unicode_data" \
        "$unicode_config" "$unicode_cache"
    cp -al -- "$DIST_ROOT"/. "$unicode_dist"/

    unicode_home_native="$(cygpath -m "$unicode_home")"
    unicode_data_native="$(cygpath -m "$unicode_data")"
    unicode_config_native="$(cygpath -m "$unicode_config")"
    unicode_cache_native="$(cygpath -m "$unicode_cache")"
    unicode_path="$unicode_dist:$unicode_dist/bin:$unicode_dist/plugins:/c/Windows/System32:/c/Windows"

    cd "$unicode_dist"
    unicode_output="$(env \
        -u LC_ALL \
        -u LC_MESSAGES \
        -u LANGUAGE \
        -u LANG \
        -u GTLS_SYSTEM_CA_FILE \
        -u SSL_CERT_FILE \
        -u SSL_CERT_DIR \
        PATH="$unicode_path" \
        HOME="$unicode_home_native" \
        USERPROFILE="$unicode_home_native" \
        XDG_DATA_HOME="$unicode_data_native" \
        XDG_CONFIG_HOME="$unicode_config_native" \
        XDG_CACHE_HOME="$unicode_cache_native" \
        DINOX_RUNTIME_SMOKE_LANGUAGE=de \
        ./dinox.exe --runtime-smoke 2>&1)" \
        || fail "packaged Unicode-path runtime smoke failed: $unicode_output"
    unicode_output="${unicode_output//$'\r'/}"
    translation_digest="$(extract_translation_digest de "$unicode_output")"
    [[ "$translation_digest" =~ ^[0-9a-f]{64}$ ]] \
        || fail "packaged Unicode-path translation was not applied: $unicode_output"
    case "$unicode_output" in
        *"DinoX Windows portable runtime smoke OK"*) ;;
        *) fail "unexpected Unicode-path runtime smoke output: $unicode_output" ;;
    esac
    # Startup caches live outside the profile so TLS initialization does not
    # modify account data before the profile lock/maintenance checks.
    [ -s "$unicode_cache/dinox/merged-ca-bundle.pem" ] \
        || fail "Unicode-path runtime smoke did not materialize the merged CA bundle at $unicode_cache/dinox/merged-ca-bundle.pem: $unicode_output"

    # OpenSSL is also a separate native process.  Its embedded manifest must
    # make direct Unicode input/output paths work while the backup password
    # remains on stdin and never enters argv or the child environment.
    unicode_openssl_root="$unicode_root/Игорь Петров/OpenSSL % ! ^ &"
    unicode_openssl_input="$unicode_openssl_root/данные äöü.bin"
    unicode_openssl_cipher="$unicode_openssl_root/зашифровано.bin"
    unicode_openssl_output="$unicode_openssl_root/восстановлено.bin"
    mkdir -p -- "$unicode_openssl_root"
    dd if=/dev/urandom of="$unicode_openssl_input" bs=1M count=8 status=none
    unicode_openssl_input_native="$(cygpath -m "$unicode_openssl_input")"
    unicode_openssl_cipher_native="$(cygpath -m "$unicode_openssl_cipher")"
    unicode_openssl_output_native="$(cygpath -m "$unicode_openssl_output")"
    if ! printf '%s' 'Ключ äöü % ! ^ &' | env PATH="$unicode_path" \
            ./bin/openssl.exe enc -aes-256-cbc -salt -pbkdf2 \
            -in "$unicode_openssl_input_native" \
            -out "$unicode_openssl_cipher_native" -pass stdin \
            >/dev/null 2>&1; then
        fail "packaged OpenSSL could not encrypt Unicode-path backup data"
    fi
    if ! printf '%s' 'Ключ äöü % ! ^ &' | env PATH="$unicode_path" \
            ./bin/openssl.exe enc -d -aes-256-cbc -pbkdf2 \
            -in "$unicode_openssl_cipher_native" \
            -out "$unicode_openssl_output_native" -pass stdin \
            >/dev/null 2>&1; then
        fail "packaged OpenSSL could not decrypt Unicode-path backup data"
    fi
    cmp -s -- "$unicode_openssl_input" "$unicode_openssl_output" \
        || fail "packaged OpenSSL Unicode-path backup roundtrip changed data"

    # Its separate Unicode fixture must survive this outer cleanup if native
    # process termination cannot be confirmed.
    run_tor_transport_runtime_smoke "$DIST_ROOT"
)

run_deferred_batch_unicode_smoke() (
    local fixture_root
    local special_root
    local temp_root
    local profile_root
    local result_root
    local launcher_source
    local launcher_exe
    local hijack_source
    local hijack_exe
    local hijack_marker
    local restart_source
    local restart_exe
    local system32_posix
    local _attempt

    command -v cygpath >/dev/null 2>&1 \
        || fail "cygpath is required for deferred Windows batch smokes"
    system32_posix="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}\\System32")"
    [ -d "$system32_posix" ] \
        || fail "Windows System32 is required for deferred Windows batch smokes"
    export PATH="$PATH:$system32_posix"
    command -v cmd.exe >/dev/null 2>&1 \
        || fail "cmd.exe is required for deferred Windows batch smokes"
    command -v cc >/dev/null 2>&1 \
        || fail "cc is required for the GSubprocess batch-launch smoke"
    command -v pkg-config >/dev/null 2>&1 \
        || fail "pkg-config is required for the GSubprocess batch-launch smoke"

    fixture_root="$(mktemp -d "$(dirname "$DIST_ROOT")/.dinox-batch-runtime.XXXXXX")"
    trap 'rm -rf -- "$fixture_root"' EXIT
    special_root="$fixture_root/Игорь & Co (100%PATH% !)^"
    temp_root="$special_root/TEMP с пробелом"
    profile_root="$special_root/Profile Петров"
    result_root="$special_root/Результаты"
    mkdir -p -- "$temp_root" "$profile_root" "$result_root"

    # Product code keeps the absolute TEMP path out of cmd.exe's /c payload:
    # GSubprocessLauncher passes the Unicode directory as CreateProcessW cwd,
    # while cmd sees only a controlled ASCII basename.  Build a tiny launcher
    # so this gate does not substitute MSYS Bash quoting.
    launcher_source="$fixture_root/gsubprocess-batch-launch.c"
    launcher_exe="$fixture_root/gsubprocess-batch-launch.exe"
    cat > "$launcher_source" <<'EOF'
#include <gio/gio.h>
#include <glib/gwin32.h>
#include <windows.h>

int
main(void)
{
    gchar **utf8_argv = g_win32_get_command_line();
    const gchar *child_argv[] = {
        NULL, "/d", "/c", NULL, NULL
    };
    GError *error = NULL;
    GSubprocessLauncher *launcher;
    GSubprocess *process;
    gchar *batch_dir;
    gchar *batch_name;
    gchar *cmd_path;
    gchar *system32_dir;
    WCHAR system32_w[MAX_PATH + 1];
    UINT system32_length;

    if (GetConsoleCP() != 0) {
        g_strfreev(utf8_argv);
        return 3;
    }
    if (!AllocConsole()) {
        g_strfreev(utf8_argv);
        return 4;
    }
    {
        HWND console_window = GetConsoleWindow();
        if (console_window != NULL)
            ShowWindow(console_window, SW_HIDE);
    }
    if (GetConsoleCP() == 0) {
        g_strfreev(utf8_argv);
        return 5;
    }
    if (utf8_argv == NULL || g_strv_length(utf8_argv) != 2) {
        g_strfreev(utf8_argv);
        return 2;
    }
    system32_length = GetSystemDirectoryW(
        system32_w, (UINT) G_N_ELEMENTS(system32_w)
    );
    if (system32_length == 0 ||
            system32_length >= (UINT) G_N_ELEMENTS(system32_w)) {
        g_strfreev(utf8_argv);
        return 9;
    }
    system32_dir = g_utf16_to_utf8(
        (const gunichar2 *) system32_w,
        (glong) system32_length,
        NULL, NULL, NULL
    );
    cmd_path = g_build_filename(system32_dir, "cmd.exe", NULL);
    if (!g_file_test(cmd_path, G_FILE_TEST_IS_REGULAR)) {
        g_free(cmd_path);
        g_free(system32_dir);
        g_strfreev(utf8_argv);
        return 10;
    }
    batch_dir = g_path_get_dirname(utf8_argv[1]);
    batch_name = g_path_get_basename(utf8_argv[1]);
    if (!g_regex_match_simple("^[A-Za-z0-9_.-]+[.]bat$", batch_name, 0, 0)) {
        g_free(batch_dir);
        g_free(batch_name);
        g_free(cmd_path);
        g_free(system32_dir);
        g_strfreev(utf8_argv);
        return 6;
    }
    child_argv[0] = cmd_path;
    child_argv[3] = batch_name;
    launcher = g_subprocess_launcher_new(
        G_SUBPROCESS_FLAGS_STDIN_PIPE |
        G_SUBPROCESS_FLAGS_STDOUT_SILENCE |
        G_SUBPROCESS_FLAGS_STDERR_SILENCE
    );
    g_subprocess_launcher_set_cwd(launcher, batch_dir);
    g_subprocess_launcher_setenv(
        launcher, "DINOX_SYSTEM32", system32_dir, TRUE
    );
    process = g_subprocess_launcher_spawnv(
        launcher,
        child_argv,
        &error
    );
    if (process == NULL) {
        g_printerr("g_subprocess_launcher_spawnv failed: %s\n", error->message);
        g_clear_error(&error);
        g_object_unref(launcher);
        g_free(batch_dir);
        g_free(batch_name);
        g_free(cmd_path);
        g_free(system32_dir);
        g_strfreev(utf8_argv);
        return 1;
    }
    g_object_unref(process);
    g_object_unref(launcher);
    g_free(batch_dir);
    g_free(batch_name);
    g_free(cmd_path);
    g_free(system32_dir);
    g_strfreev(utf8_argv);
    return 0;
}
EOF
    # shellcheck disable=SC2046
    (cd "$fixture_root" && \
        cc -O2 -mwindows -o gsubprocess-batch-launch.exe gsubprocess-batch-launch.c \
            $(pkg-config --cflags --libs gio-2.0)) \
        || fail "could not build the GSubprocess batch-launch fixture"

    # A user-controlled TEMP directory must never override cmd.exe or the
    # external System32 tools used inside a deferred batch.
    hijack_source="$fixture_root/cwd-search-hijack.c"
    hijack_exe="$fixture_root/cwd-search-hijack.exe"
    hijack_marker="$temp_root/dinox-cwd-search-hijack.marker"
    cat > "$hijack_source" <<'EOF'
#include <windows.h>

int
main(void)
{
    HANDLE marker = CreateFileW(
        L"dinox-cwd-search-hijack.marker",
        GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );
    if (marker == INVALID_HANDLE_VALUE)
        return 1;
    CloseHandle(marker);
    return 0;
}
EOF
    (cd "$fixture_root" && \
        cc -O2 -mwindows -o cwd-search-hijack.exe cwd-search-hijack.c) \
        || fail "could not build the deferred-batch cwd-hijack fixture"
    cp "$hijack_exe" "$temp_root/cmd.exe"
    cp "$hijack_exe" "$temp_root/ping.exe"

    restart_source="$fixture_root/restart-marker.c"
    restart_exe="$fixture_root/restart-marker.exe"
    cat > "$restart_source" <<'EOF'
#include <windows.h>

int
main(void)
{
    HANDLE file;
    const char marker_byte = '1';
    DWORD written = 0;

    file = CreateFileW(
        L"restart.marker",
        GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );
    if (file == INVALID_HANDLE_VALUE)
        return 1;
    if (!WriteFile(file, &marker_byte, 1, &written, NULL) || written != 1) {
        CloseHandle(file);
        return 2;
    }
    CloseHandle(file);
    return 0;
}
EOF
    (cd "$fixture_root" && \
        cc -O2 -mwindows -o restart-marker.exe restart-marker.c) \
        || fail "could not build the deferred restart marker fixture"

    batch_begin() {
        local batch_path="$1"
        # Keep this byte-for-byte aligned with windows_batch_prelude().  The
        # first line must stay ASCII and the file must stay UTF-8 without BOM.
        printf '%s\r\n' \
            '@chcp 65001 >nul 2>&1 || exit /b 1' \
            '@echo off' \
            'setlocal DisableDelayedExpansion' > "$batch_path"
        [ "$(od -An -tx1 -N3 "$batch_path" | tr -d ' \n')" = "406368" ] \
            || fail "deferred batch fixture is not BOMless UTF-8 with an ASCII prelude"
    }

    batch_set_path() {
        local batch_path="$1"
        local variable_name="$2"
        local path="$3"
        local native_path
        local escaped_path
        native_path="$(cygpath -w "$path")"
        escaped_path="${native_path//%/%%}"
        printf 'set "%s=%s"\r\n' \
            "$variable_name" "$escaped_path" >> "$batch_path"
    }

    batch_set_restart_executable() {
        local batch_path="$1"
        local executable_path="$2"
        [ "$(basename -- "$executable_path")" = "dinox.exe" ] \
            || fail "deferred restart fixture executable must be named dinox.exe"
        batch_set_path "$batch_path" "DINOX_EXE_DIR" \
            "$(dirname -- "$executable_path")"
    }

    batch_start_restart_executable() {
        local batch_path="$1"
        batch_line "$batch_path" 'pushd "%DINOX_EXE_DIR%" || exit /b 1'
        batch_line "$batch_path" \
            'start "" "dinox.exe" || (popd & exit /b 1)'
        batch_line "$batch_path" 'popd'
    }

    batch_line() {
        printf '%s\r\n' "$2" >> "$1"
    }

    launch_batch_and_wait() {
        local label="$1"
        local batch_path="$2"
        local status_path="$3"
        local batch_native
        local launch_status
        local launch_log="$result_root/${label}.launch.log"

        batch_native="$(cygpath -w "$batch_path")"
        set +e
        MSYS2_ARG_CONV_EXCL='*' "$launcher_exe" "$batch_native" \
            >"$launch_log" 2>&1
        launch_status=$?
        set -e
        [ "$launch_status" -eq 0 ] \
            || fail "$label GSubprocessLauncher cmd.exe /d /c returned $launch_status"

        for _attempt in {1..150}; do
            if [ -s "$status_path" ] && [ ! -e "$batch_path" ]; then
                break
            fi
            sleep 0.1
        done
        [ -s "$status_path" ] \
            || fail "$label batch did not publish an exit result"
        [ "$(tr -d '\r\n' < "$status_path")" = "0" ] \
            || fail "$label batch reported failure: $(tr '\r\n' '  ' < "$status_path")"
        [ ! -e "$batch_path" ] \
            || fail "$label batch did not delete itself"
    }

    wait_for_marker() {
        local label="$1"
        local marker_path="$2"
        for _attempt in {1..100}; do
            [ -s "$marker_path" ] && break
            sleep 0.1
        done
        [ -s "$marker_path" ] \
            || fail "$label restart marker was not created"
    }

    write_restart_helper() {
        local helper_path="$1"
        mkdir -p -- "$(dirname -- "$helper_path")"
        cp "$restart_exe" "$helper_path"
    }

    # Staged restore: move the active profile to rollback, move the staged
    # profile into place, and remove the now-empty staging root.
    local restore_active="$profile_root/Active dinox"
    local restore_rollback="$profile_root/Rollback dinox"
    local restore_stage_root="$profile_root/Stage Корень"
    local restore_staged="$restore_stage_root/dinox"
    local restore_batch="$temp_root/dinox_restore_apply_fixture.bat"
    local restore_status="$result_root/restore.status"
    local restore_log="$result_root/restore.log"
    local restore_restart="$profile_root/Restore Restart Игорь/dinox.exe"
    local restore_restart_marker="$profile_root/Restore Restart Игорь/restart.marker"
    mkdir -p -- "$restore_active" "$restore_staged"
    printf '%s\n' old > "$restore_active/old.marker"
    printf '%s\n' new > "$restore_staged/new.marker"
    write_restart_helper "$restore_restart"
    batch_begin "$restore_batch"
    batch_set_path "$restore_batch" "ACTIVE" "$restore_active"
    batch_set_path "$restore_batch" "STAGED" "$restore_staged"
    batch_set_path "$restore_batch" "STAGING_ROOT" "$restore_stage_root"
    batch_set_path "$restore_batch" "ROLLBACK" "$restore_rollback"
    batch_set_restart_executable "$restore_batch" "$restore_restart"
    batch_set_path "$restore_batch" "LOG" "$restore_log"
    batch_set_path "$restore_batch" "STATUS" "$restore_status"
    batch_line "$restore_batch" '> "%LOG%" echo Applying staged restore fixture.'
    batch_line "$restore_batch" 'move /Y "%ACTIVE%" "%ROLLBACK%" >> "%LOG%" 2>&1'
    batch_line "$restore_batch" 'if exist "%ACTIVE%" goto restore_failed'
    batch_line "$restore_batch" 'move /Y "%STAGED%" "%ACTIVE%" >> "%LOG%" 2>&1'
    batch_line "$restore_batch" 'if exist "%STAGED%" goto restore_failed'
    batch_line "$restore_batch" 'if exist "%STAGING_ROOT%" rd /s /q "%STAGING_ROOT%"'
    batch_start_restart_executable "$restore_batch"
    batch_line "$restore_batch" '> "%STATUS%" echo 0'
    batch_line "$restore_batch" '(goto) 2>nul & del "%~f0"'
    batch_line "$restore_batch" 'exit /b 0'
    batch_line "$restore_batch" ':restore_failed'
    batch_line "$restore_batch" '> "%STATUS%" echo 1'
    batch_line "$restore_batch" 'exit /b 1'
    launch_batch_and_wait "restore" "$restore_batch" "$restore_status"
    wait_for_marker "restore" "$restore_restart_marker"
    [ -s "$restore_active/new.marker" ] \
        || fail "restore batch did not activate the staged profile"
    [ -s "$restore_rollback/old.marker" ] \
        || fail "restore batch did not preserve the rollback profile"
    [ ! -e "$restore_stage_root" ] \
        || fail "restore batch left the staging root behind"

    # Panic wipe: delete current and legacy data/config/cache trees.
    local wipe_data="$profile_root/Wipe Data/dinox"
    local wipe_config="$profile_root/Wipe Config/dinox"
    local wipe_cache="$profile_root/Wipe Cache/dinox"
    local wipe_old_data="$profile_root/Wipe Data/dino"
    local wipe_old_config="$profile_root/Wipe Config/dino"
    local wipe_old_cache="$profile_root/Wipe Cache/dino"
    local wipe_batch="$temp_root/dinox_wipe_fixture.bat"
    local wipe_status="$result_root/wipe.status"
    mkdir -p -- \
        "$wipe_data" "$wipe_config" "$wipe_cache" \
        "$wipe_old_data" "$wipe_old_config" "$wipe_old_cache"
    for path in \
            "$wipe_data" "$wipe_config" "$wipe_cache" \
            "$wipe_old_data" "$wipe_old_config" "$wipe_old_cache"; do
        printf '%s\n' delete > "$path/delete.marker"
    done
    batch_begin "$wipe_batch"
    batch_set_path "$wipe_batch" "DATA_DIR" "$wipe_data"
    batch_set_path "$wipe_batch" "CONFIG_DIR" "$wipe_config"
    batch_set_path "$wipe_batch" "CACHE_DIR" "$wipe_cache"
    batch_set_path "$wipe_batch" "OLD_DATA_DIR" "$wipe_old_data"
    batch_set_path "$wipe_batch" "OLD_CONFIG_DIR" "$wipe_old_config"
    batch_set_path "$wipe_batch" "OLD_CACHE_DIR" "$wipe_old_cache"
    batch_set_path "$wipe_batch" "STATUS" "$wipe_status"
    batch_line "$wipe_batch" '"%DINOX_SYSTEM32%\ping.exe" 127.0.0.1 -n 2 > nul'
    batch_line "$wipe_batch" 'rd /s /q "%DATA_DIR%" 2>nul'
    batch_line "$wipe_batch" 'rd /s /q "%CONFIG_DIR%" 2>nul'
    batch_line "$wipe_batch" 'rd /s /q "%CACHE_DIR%" 2>nul'
    batch_line "$wipe_batch" 'rd /s /q "%OLD_DATA_DIR%" 2>nul'
    batch_line "$wipe_batch" 'rd /s /q "%OLD_CONFIG_DIR%" 2>nul'
    batch_line "$wipe_batch" 'rd /s /q "%OLD_CACHE_DIR%" 2>nul'
    batch_line "$wipe_batch" '> "%STATUS%" echo 0'
    batch_line "$wipe_batch" '(goto) 2>nul & del "%~f0"'
    launch_batch_and_wait "wipe" "$wipe_batch" "$wipe_status"
    for path in \
            "$wipe_data" "$wipe_config" "$wipe_cache" \
            "$wipe_old_data" "$wipe_old_config" "$wipe_old_cache"; do
        [ ! -e "$path" ] || fail "wipe batch left a profile tree behind: $path"
    done

    # Database reset: preserve unrelated profile data, delete every database
    # sidecar plus OMEMO state, then prove the quoted restart helper launches.
    local db_data="$profile_root/DB Reset/dinox"
    local db_batch="$temp_root/dinox_reset_fixture.bat"
    local db_status="$result_root/db-reset.status"
    local db_restart="$profile_root/DB Restart Игорь/dinox.exe"
    local db_restart_marker="$profile_root/DB Restart Игорь/restart.marker"
    local db_file
    local -a db_files=(
        dino.db dino.db-shm dino.db-wal
        pgp.db pgp.db-shm pgp.db-wal
        bot_registry.db bot_registry.db-shm bot_registry.db-wal
        omemo.db omemo.db-shm omemo.db-wal
        mqtt.db mqtt.db-shm mqtt.db-wal omemo.key
    )
    mkdir -p -- "$db_data/omemo"
    printf '%s\n' keep > "$db_data/keep.marker"
    printf '%s\n' delete > "$db_data/omemo/delete.marker"
    for db_file in "${db_files[@]}"; do
        printf '%s\n' delete > "$db_data/$db_file"
    done
    write_restart_helper "$db_restart"
    batch_begin "$db_batch"
    batch_set_path "$db_batch" "DATA_DIR" "$db_data"
    batch_set_restart_executable "$db_batch" "$db_restart"
    batch_set_path "$db_batch" "STATUS" "$db_status"
    batch_line "$db_batch" '"%DINOX_SYSTEM32%\ping.exe" 127.0.0.1 -n 3 > nul'
    for db_file in "${db_files[@]}"; do
        batch_line "$db_batch" "del /f /q \"%DATA_DIR%\\$db_file\" 2>nul"
    done
    batch_line "$db_batch" 'rd /s /q "%DATA_DIR%\omemo" 2>nul'
    batch_start_restart_executable "$db_batch"
    batch_line "$db_batch" '> "%STATUS%" echo 0'
    batch_line "$db_batch" '(goto) 2>nul & del "%~f0"'
    launch_batch_and_wait "db-reset" "$db_batch" "$db_status"
    wait_for_marker "db-reset" "$db_restart_marker"
    [ -s "$db_data/keep.marker" ] \
        || fail "database reset batch deleted unrelated profile data"
    [ ! -e "$db_data/omemo" ] \
        || fail "database reset batch left the OMEMO directory behind"
    for db_file in "${db_files[@]}"; do
        [ ! -e "$db_data/$db_file" ] \
            || fail "database reset batch left $db_file behind"
    done

    # Factory reset: delete all three current trees and prove restart launch.
    local factory_data="$profile_root/Factory Data/dinox"
    local factory_config="$profile_root/Factory Config/dinox"
    local factory_cache="$profile_root/Factory Cache/dinox"
    local factory_batch="$temp_root/dinox_factory_reset_fixture.bat"
    local factory_status="$result_root/factory-reset.status"
    local factory_restart="$profile_root/Factory Restart Игорь/dinox.exe"
    local factory_restart_marker="$profile_root/Factory Restart Игорь/restart.marker"
    mkdir -p -- "$factory_data" "$factory_config" "$factory_cache"
    printf '%s\n' delete > "$factory_data/delete.marker"
    printf '%s\n' delete > "$factory_config/delete.marker"
    printf '%s\n' delete > "$factory_cache/delete.marker"
    write_restart_helper "$factory_restart"
    batch_begin "$factory_batch"
    batch_set_path "$factory_batch" "DATA_DIR" "$factory_data"
    batch_set_path "$factory_batch" "CONFIG_DIR" "$factory_config"
    batch_set_path "$factory_batch" "CACHE_DIR" "$factory_cache"
    batch_set_restart_executable "$factory_batch" "$factory_restart"
    batch_set_path "$factory_batch" "STATUS" "$factory_status"
    batch_line "$factory_batch" '"%DINOX_SYSTEM32%\ping.exe" 127.0.0.1 -n 3 > nul'
    batch_line "$factory_batch" 'rd /s /q "%DATA_DIR%" 2>nul'
    batch_line "$factory_batch" 'rd /s /q "%CONFIG_DIR%" 2>nul'
    batch_line "$factory_batch" 'rd /s /q "%CACHE_DIR%" 2>nul'
    batch_start_restart_executable "$factory_batch"
    batch_line "$factory_batch" '> "%STATUS%" echo 0'
    batch_line "$factory_batch" '(goto) 2>nul & del "%~f0"'
    launch_batch_and_wait "factory-reset" "$factory_batch" "$factory_status"
    wait_for_marker "factory-reset" "$factory_restart_marker"
    [ ! -e "$factory_data" ] \
        || fail "factory reset batch left the data tree behind"
    [ ! -e "$factory_config" ] \
        || fail "factory reset batch left the config tree behind"
    [ ! -e "$factory_cache" ] \
        || fail "factory reset batch left the cache tree behind"

    # Standalone restart_application(): delay, launch the quoted target and
    # remove the outer deferred batch through the same safe launcher.
    local restart_batch="$temp_root/dinox_restart_fixture.bat"
    local restart_status="$result_root/restart.status"
    local restart_target="$profile_root/Standalone Restart Игорь/dinox.exe"
    local restart_marker="$profile_root/Standalone Restart Игорь/restart.marker"
    write_restart_helper "$restart_target"
    batch_begin "$restart_batch"
    batch_set_restart_executable "$restart_batch" "$restart_target"
    batch_set_path "$restart_batch" "STATUS" "$restart_status"
    batch_line "$restart_batch" '"%DINOX_SYSTEM32%\ping.exe" 127.0.0.1 -n 2 > nul'
    batch_start_restart_executable "$restart_batch"
    batch_line "$restart_batch" '> "%STATUS%" echo 0'
    batch_line "$restart_batch" '(goto) 2>nul & del "%~f0"'
    launch_batch_and_wait "restart" "$restart_batch" "$restart_status"
    wait_for_marker "restart" "$restart_marker"
    [ ! -e "$hijack_marker" ] \
        || fail "deferred batch executed a helper from its user-controlled cwd"

    echo "OK: deferred Windows Unicode batches (restore/wipe/db-reset/factory-reset/restart)"
)

run_unicode_path_runtime_smoke
run_deferred_batch_unicode_smoke

command -v ldd >/dev/null 2>&1 || fail "ldd is required for the portable DLL closure gate"
ldd_bin="$(command -v ldd)"
checked_pe=0
while IFS= read -r -d '' artifact; do
    if ! ldd_output="$(env PATH="$portable_path" "$ldd_bin" "$artifact" 2>&1)"; then
        echo "$ldd_output" >&2
        fail "DLL dependency probe failed: ${artifact#./}"
    fi
    if grep -qi 'not found' <<< "$ldd_output"; then
        echo "$ldd_output" >&2
        fail "unresolved DLL dependency: ${artifact#./}"
    fi
    if grep -Eqi '(^|[[:space:]=>])(/mingw64/|/ucrt64/|/clang64/|/usr/bin/|[A-Z]:\\\\msys64\\\\(mingw64|usr\\\\bin)\\\\)' \
            <<< "$ldd_output" \
            || grep -Fqi "$PROJECT_BUILD_POSIX" <<< "$ldd_output" \
            || { [ -n "$PROJECT_BUILD_WINDOWS" ] \
                && grep -Fqi "$PROJECT_BUILD_WINDOWS" <<< "$ldd_output"; }; then
        echo "$ldd_output" >&2
        fail "packaged artifact resolves a dependency from the build environment: ${artifact#./}"
    fi
    checked_pe=$((checked_pe + 1))
done < <(find . -type f \( -iname '*.exe' -o -iname '*.dll' \) -print0)

[ "$checked_pe" -gt 0 ] || fail "no PE files found in Windows distribution"
echo "OK: complete portable Windows dist ($checked_pe PE files checked)"
