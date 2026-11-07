#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PARENT="$(cd "$PROJECT_ROOT/.." && pwd)"
WINDOWS_VENDOR_ROOT="${DINOX_WINDOWS_VENDOR_ROOT:-$PROJECT_PARENT/vendor-deps}"

usage() {
    echo "Usage: $0 [--preflight-runtime-helpers|--self-test|-h|--help]"
    echo
    echo "Builds the DinoX Windows distribution in dist/."
    echo "Set DINOX_BUILD_DIR to package a Meson build directory other than build/."
    echo "Set DINOX_LYREBIRD_PATH to package a validated Lyrebird binary explicitly."
}

TOR_REQUIRED_VERSION="0.4.9.12"
LYREBIRD_REQUIRED_VERSION="0.8.1"

fail() {
    echo "  [ERROR] $*" >&2
    return 1
}

locate_tor_binary() {
    local path

    if [ -f "/mingw64/bin/tor.exe" ]; then
        printf '%s\n' "/mingw64/bin/tor.exe"
        return 0
    fi

    if path="$(command -v tor 2>/dev/null)" && [[ "$path" == /mingw64/* ]]; then
        printf '%s\n' "$path"
        return 0
    fi

    return 1
}

locate_lyrebird_binary() {
    local explicit="${DINOX_LYREBIRD_PATH:-}"
    local path

    if [ -n "$explicit" ]; then
        [ -f "$explicit" ] || return 1
        printf '%s\n' "$explicit"
        return 0
    fi

    for path in \
        "/mingw64/bin/lyrebird.exe" \
        "$HOME/go/bin/lyrebird.exe"; do
        if [ -f "$path" ]; then
            printf '%s\n' "$path"
            return 0
        fi
    done

    if path="$(command -v lyrebird.exe 2>/dev/null)"; then
        printf '%s\n' "$path"
        return 0
    fi

    return 1
}

finish_dist_rebuild() {
    local status=$?
    trap - EXIT

    if [ "$status" -ne 0 ]; then
        echo "  [ERROR] Distribution build failed; removing the incomplete dist/." >&2
        rm -rf dist
    fi

    exit "$status"
}

require_tor_version() {
    local bin="$1"
    local output
    local first_line
    local version

    if [ ! -f "$bin" ]; then
        fail "Required native Windows Tor binary not found: $bin"
        return 1
    fi
    if [ ! -x "$bin" ]; then
        fail "Required native Windows Tor binary is not executable: $bin"
        return 1
    fi
    if ! output="$("$bin" --version 2>/dev/null)"; then
        fail "Unable to execute required native Windows Tor binary: $bin"
        return 1
    fi

    first_line="${output%%$'\n'*}"
    version="$(sed -nE 's/^Tor version ([0-9]+(\.[0-9]+)*).*/\1/p' <<< "$first_line")"
    if [ "$version" != "$TOR_REQUIRED_VERSION" ]; then
        echo "  [ERROR] tor.exe version ${version:-unknown}, expected $TOR_REQUIRED_VERSION" >&2
        echo "          Install the validated mingw-w64-x86_64-tor package before building." >&2
        return 1
    fi
    echo "  [OK] tor.exe version $version"
}

require_lyrebird_version() {
    local bin="$1"
    local output
    local first_line
    local version
    local attempt
    local max_attempts=1

    if [ ! -f "$bin" ]; then
        fail "Required Lyrebird binary not found: $bin"
        return 1
    fi
    if [ ! -x "$bin" ]; then
        fail "Required Lyrebird binary is not executable: $bin"
        return 1
    fi
    # Windows security scanners can briefly keep a newly copied PE executable
    # from starting even though the copy is complete and byte-identical. Retry
    # only real PE files; shell-script fixtures in --self-test still fail
    # immediately and deterministic version errors are not hidden.
    if [ "$(head -c 2 "$bin" 2>/dev/null || true)" = "MZ" ]; then
        max_attempts=5
    fi
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if output="$("$bin" --version 2>/dev/null)"; then
            break
        fi
        if [ "$attempt" -eq "$max_attempts" ]; then
            fail "Unable to execute required Lyrebird binary after $max_attempts attempt(s): $bin"
            return 1
        fi
        sleep 0.5
    done

    first_line="${output%%$'\n'*}"
    version="$(sed -nE 's/^lyrebird ([^[:space:]]+).*/\1/p' <<< "$first_line")"
    if [ "$version" != "$LYREBIRD_REQUIRED_VERSION" ]; then
        echo "  [ERROR] lyrebird.exe version ${version:-unknown}, expected $LYREBIRD_REQUIRED_VERSION" >&2
        echo "          Rebuild Lyrebird with: -ldflags '-s -w -X main.lyrebirdVersion=$LYREBIRD_REQUIRED_VERSION'" >&2
        return 1
    fi
    echo "  [OK] lyrebird.exe version $version"
}

preflight_runtime_helpers() {
    local tor_path
    local lyrebird_path

    if ! tor_path="$(locate_tor_binary)"; then
        fail "Native /mingw64/bin/tor.exe is required for the complete Windows distribution."
        return 1
    fi
    require_tor_version "$tor_path" || return 1

    if ! lyrebird_path="$(locate_lyrebird_binary)"; then
        if [ -n "${DINOX_LYREBIRD_PATH:-}" ]; then
            fail "DINOX_LYREBIRD_PATH does not point to a file: $DINOX_LYREBIRD_PATH"
        else
            fail "Lyrebird $LYREBIRD_REQUIRED_VERSION is required for the complete Windows distribution."
        fi
        return 1
    fi
    require_lyrebird_version "$lyrebird_path" || return 1
}

expect_helper_rejected() {
    local label="$1"
    shift
    local status

    set +e
    "$@" >/dev/null 2>&1
    status=$?
    set -e
    if [ "$status" -ne 1 ]; then
        echo "Self-test failed: $label returned $status instead of 1" >&2
        return 1
    fi
}

create_pixbuf_loader_cache() {
    local source_loader_dir="$1"
    local dist_loader_dir="$2"
    local cache_path="$3"
    local query_tool="${4:-gdk-pixbuf-query-loaders}"
    local source_loader
    local filename
    local dist_loader_count
    local -a source_loaders=()
    local -a native_source_loaders=()

    while IFS= read -r -d '' source_loader; do
        source_loaders+=("$source_loader")
    done < <(
        find "$source_loader_dir" -maxdepth 1 -type f -iname '*.dll' \
            ! -iname 'io-wmf.dll' -print0 | sort -z
    )
    [ "${#source_loaders[@]}" -gt 0 ] \
        || { fail "No GDK-Pixbuf source loaders found in $source_loader_dir"; return 1; }

    dist_loader_count="$(
        find "$dist_loader_dir" -maxdepth 1 -type f -iname '*.dll' | wc -l
    )"
    [ "$dist_loader_count" -eq "${#source_loaders[@]}" ] || {
        fail "GDK-Pixbuf source/dist loader count differs (${#source_loaders[@]} != $dist_loader_count)"
        return 1
    }

    for source_loader in "${source_loaders[@]}"; do
        filename="$(basename "$source_loader")"
        [ -f "$dist_loader_dir/$filename" ] || {
            fail "Copied GDK-Pixbuf loader is missing: $filename"
            return 1
        }
        if command -v cygpath >/dev/null 2>&1; then
            native_source_loaders+=("$(cygpath -m "$source_loader")")
        else
            native_source_loaders+=("$source_loader")
        fi
    done

    if ! MSYS2_ARG_CONV_EXCL='*' "$query_tool" \
            "${native_source_loaders[@]}" > "$cache_path"; then
        fail "gdk-pixbuf-query-loaders failed"
        return 1
    fi

    python3 - "$cache_path" "$dist_loader_dir" <<'PY'
import collections
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
dist_loader_dir = pathlib.Path(sys.argv[2])
lines = path.read_text(encoding="utf-8").splitlines()
expected = collections.Counter(
    item.name.casefold()
    for item in dist_loader_dir.iterdir()
    if item.is_file() and item.suffix.casefold() == ".dll"
)
observed = collections.Counter()
rewritten = []
for line in lines:
    if line.startswith("# LoaderDir = "):
        line = "# LoaderDir = @DINOX_GDK_PIXBUF_MODULEDIR@"
    match = re.fullmatch(r'"([^"]+\.dll)"', line, flags=re.IGNORECASE)
    if match:
        filename = match.group(1).replace("\\", "/").rsplit("/", 1)[-1]
        observed[filename.casefold()] += 1
        line = f'"@DINOX_GDK_PIXBUF_MODULEDIR@/{filename}"'
    rewritten.append(line)
if observed != expected:
    missing = sorted((expected - observed).elements())
    extra = sorted((observed - expected).elements())
    raise SystemExit(
        "FAIL: pixbuf cache loader set differs from copied DLLs "
        f"(missing={missing}, extra_or_duplicate={extra})"
    )
path.write_text("\n".join(rewritten) + "\n", encoding="utf-8", newline="\n")
PY
}

copy_expected_catalog_set() {
    local linguas_file="$1"
    local build_po_root="$2"
    local domain="$3"
    local dist_locale_root="$4"
    local raw
    local lang
    local source_catalog
    local target_dir
    local -a line_languages=()
    local count=0

    [ -s "$linguas_file" ] \
        || { fail "LINGUAS file missing or empty: $linguas_file"; return 1; }

    while IFS= read -r raw || [ -n "$raw" ]; do
        raw="${raw//$'\r'/}"
        raw="${raw%%#*}"
        read -r -a line_languages <<< "$raw"
        for lang in "${line_languages[@]}"; do
            case "$lang" in
                *[!A-Za-z0-9_.@-]*)
                    fail "Invalid locale '$lang' in $linguas_file"
                    return 1
                    ;;
            esac

            source_catalog="$build_po_root/$lang/LC_MESSAGES/$domain.mo"
            [ -s "$source_catalog" ] || {
                fail "Expected translation was not built or is empty: $source_catalog"
                return 1
            }
            target_dir="$dist_locale_root/$lang/LC_MESSAGES"
            mkdir -p -- "$target_dir"
            cp -- "$source_catalog" "$target_dir/$domain.mo"
            [ -s "$target_dir/$domain.mo" ] || {
                fail "Copied translation is missing or empty: $target_dir/$domain.mo"
                return 1
            }
            count=$((count + 1))
        done
    done < "$linguas_file"

    [ "$count" -gt 0 ] || {
        fail "LINGUAS file contains no locales: $linguas_file"
        return 1
    }
    CATALOG_SET_COUNT="$count"
}

copy_runtime_catalogs() {
    local source_locale_root="$1"
    local dist_locale_root="$2"
    local source_catalog
    local target_dir
    local lang
    local domain
    local domain_count
    local count=0
    local -a required_languages=(de ru)
    local -a runtime_domains=(gtk40 glib20 gdk-pixbuf libadwaita)

    [ -d "$source_locale_root" ] || {
        fail "GTK runtime locale directory not found: $source_locale_root"
        return 1
    }

    # German and Russian exercise both the normal Latin path and the Windows
    # Unicode locale path used by affected users. Every runtime gettext domain
    # shipped by the portable package must provide both catalogs.
    for lang in "${required_languages[@]}"; do
        for domain in "${runtime_domains[@]}"; do
            source_catalog="$source_locale_root/$lang/LC_MESSAGES/$domain.mo"
            [ -s "$source_catalog" ] || {
                fail "Required GTK runtime translation missing or empty: $source_catalog"
                return 1
            }
        done
    done

    for domain in "${runtime_domains[@]}"; do
        domain_count=0
        for source_catalog in "$source_locale_root"/*/LC_MESSAGES/"$domain.mo"; do
            [ -e "$source_catalog" ] || continue
            [ -s "$source_catalog" ] || {
                fail "GTK runtime translation is empty: $source_catalog"
                return 1
            }
            lang="$(basename "$(dirname "$(dirname "$source_catalog")")")"
            target_dir="$dist_locale_root/$lang/LC_MESSAGES"
            mkdir -p -- "$target_dir"
            cp -- "$source_catalog" "$target_dir/$domain.mo"
            [ -s "$target_dir/$domain.mo" ] || {
                fail "Copied GTK runtime translation is missing or empty: $target_dir/$domain.mo"
                return 1
            }
            domain_count=$((domain_count + 1))
            count=$((count + 1))
        done
        [ "$domain_count" -gt 0 ] || {
            fail "GTK runtime translation domain is unavailable: $domain"
            return 1
        }
    done

    [ "$count" -gt 0 ] || {
        fail "No GTK runtime translations were copied"
        return 1
    }
    RUNTIME_CATALOG_COUNT="$count"
}

run_self_test() (
    local tmpdir
    local manifest_embed_count
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    python3 "$PROJECT_ROOT/scripts/embed-windows-utf8-manifest.py" self-test \
        >/dev/null
    manifest_embed_count="$(awk \
        '$1 == "python3" && $2 == "scripts/embed-windows-utf8-manifest.py" && $3 == "embed" { count++ } END { print count + 0 }' \
        "$PROJECT_ROOT/scripts/update_dist.sh")"
    [ "$manifest_embed_count" -eq 2 ] \
        || fail "OpenSSL/Tor UTF-8 process-manifest embedding is incomplete"

    printf '%s\n' '#!/usr/bin/env bash' 'echo "Tor version 0.4.9.12."' > "$tmpdir/tor-good.exe"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "Tor version 0.4.8.0."' > "$tmpdir/tor-wrong.exe"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 42' > "$tmpdir/tor-broken.exe"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "lyrebird 0.8.1"' > "$tmpdir/lyrebird-good.exe"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "lyrebird 0.7.0"' > "$tmpdir/lyrebird-wrong.exe"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 42' > "$tmpdir/lyrebird-broken.exe"
    chmod +x \
        "$tmpdir/tor-good.exe" \
        "$tmpdir/tor-wrong.exe" \
        "$tmpdir/tor-broken.exe" \
        "$tmpdir/lyrebird-good.exe" \
        "$tmpdir/lyrebird-wrong.exe" \
        "$tmpdir/lyrebird-broken.exe"
    : > "$tmpdir/not-executable.exe"

    require_tor_version "$tmpdir/tor-good.exe" >/dev/null
    require_lyrebird_version "$tmpdir/lyrebird-good.exe" >/dev/null

    expect_helper_rejected "missing Tor" require_tor_version "$tmpdir/missing-tor.exe"
    expect_helper_rejected "non-executable Tor" require_tor_version "$tmpdir/not-executable.exe"
    expect_helper_rejected "broken Tor" require_tor_version "$tmpdir/tor-broken.exe"
    expect_helper_rejected "wrong Tor version" require_tor_version "$tmpdir/tor-wrong.exe"
    expect_helper_rejected "missing Lyrebird" require_lyrebird_version "$tmpdir/missing-lyrebird.exe"
    expect_helper_rejected "non-executable Lyrebird" require_lyrebird_version "$tmpdir/not-executable.exe"
    expect_helper_rejected "broken Lyrebird" require_lyrebird_version "$tmpdir/lyrebird-broken.exe"
    expect_helper_rejected "wrong Lyrebird version" require_lyrebird_version "$tmpdir/lyrebird-wrong.exe"

    mkdir -p "$tmpdir/source-loaders" "$tmpdir/Игорь/dist-loaders"
    : > "$tmpdir/source-loaders/libpixbufloader-png.dll"
    : > "$tmpdir/source-loaders/pixbufloader_svg.dll"
    : > "$tmpdir/source-loaders/io-wmf.dll"
    cp "$tmpdir/source-loaders/libpixbufloader-png.dll" "$tmpdir/Игорь/dist-loaders/"
    cp "$tmpdir/source-loaders/pixbufloader_svg.dll" "$tmpdir/Игорь/dist-loaders/"
    cat > "$tmpdir/fake-query-loaders" <<'SH'
#!/usr/bin/env bash
printf '%s\n' \
    '# GdkPixbuf Image Loader Modules file' \
    '# Created by update_dist.sh self-test'
for loader in "$@"; do
    printf '"%s"\n\n' "$loader"
done
SH
    chmod +x "$tmpdir/fake-query-loaders"
    create_pixbuf_loader_cache \
        "$tmpdir/source-loaders" \
        "$tmpdir/Игорь/dist-loaders" \
        "$tmpdir/Игорь/loaders.cache" \
        "$tmpdir/fake-query-loaders"
    [ "$(
        grep -Ec '^"@DINOX_GDK_PIXBUF_MODULEDIR@/[^"]+[.][dD][lL][lL]"$' \
            "$tmpdir/Игорь/loaders.cache"
    )" -eq 2 ]
    ! grep -F "$tmpdir" "$tmpdir/Игорь/loaders.cache" >/dev/null

    mkdir -p \
        "$tmpdir/Исходники с пробелом" \
        "$tmpdir/Сборка с пробелом/de/LC_MESSAGES" \
        "$tmpdir/Сборка с пробелом/ru/LC_MESSAGES"
    printf '%s\n' '# fixture locales' 'de ru' \
        > "$tmpdir/Исходники с пробелом/LINGUAS"
    printf '%s\n' 'de fixture' \
        > "$tmpdir/Сборка с пробелом/de/LC_MESSAGES/dino.mo"
    printf '%s\n' 'ru fixture' \
        > "$tmpdir/Сборка с пробелом/ru/LC_MESSAGES/dino.mo"
    copy_expected_catalog_set \
        "$tmpdir/Исходники с пробелом/LINGUAS" \
        "$tmpdir/Сборка с пробелом" \
        dino \
        "$tmpdir/Пакет с пробелом/locale"
    [ "$CATALOG_SET_COUNT" -eq 2 ]
    [ -s "$tmpdir/Пакет с пробелом/locale/de/LC_MESSAGES/dino.mo" ]
    [ -s "$tmpdir/Пакет с пробелом/locale/ru/LC_MESSAGES/dino.mo" ]
    rm "$tmpdir/Сборка с пробелом/ru/LC_MESSAGES/dino.mo"
    expect_helper_rejected \
        "missing expected DinoX translation" \
        copy_expected_catalog_set \
        "$tmpdir/Исходники с пробелом/LINGUAS" \
        "$tmpdir/Сборка с пробелом" \
        dino \
        "$tmpdir/Fehlendes Paket/locale"

    for lang in de ru fr; do
        mkdir -p "$tmpdir/GTK Quelle/$lang/LC_MESSAGES"
        for domain in gtk40 glib20 gdk-pixbuf libadwaita; do
            printf '%s\n' "$lang $domain fixture" \
                > "$tmpdir/GTK Quelle/$lang/LC_MESSAGES/$domain.mo"
        done
    done
    copy_runtime_catalogs \
        "$tmpdir/GTK Quelle" \
        "$tmpdir/GTK Paket/share/locale"
    [ "$RUNTIME_CATALOG_COUNT" -eq 12 ]
    [ -s "$tmpdir/GTK Paket/share/locale/de/LC_MESSAGES/gtk40.mo" ]
    [ -s "$tmpdir/GTK Paket/share/locale/ru/LC_MESSAGES/libadwaita.mo" ]
    rm "$tmpdir/GTK Quelle/ru/LC_MESSAGES/glib20.mo"
    expect_helper_rejected \
        "missing required GTK runtime translation" \
        copy_runtime_catalogs \
        "$tmpdir/GTK Quelle" \
        "$tmpdir/Fehlendes GTK Paket/share/locale"

    echo "Self-test OK"
)

case "${1:-}" in
    -h|--help)
        [ "$#" -eq 1 ] || { usage >&2; exit 2; }
        usage
        exit 0
        ;;
    --preflight-runtime-helpers)
        [ "$#" -eq 1 ] || { usage >&2; exit 2; }
        preflight_runtime_helpers
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

cd "$PROJECT_ROOT"
BUILD_DIR="${DINOX_BUILD_DIR:-build}"
if [ ! -d "$BUILD_DIR" ]; then
    echo "Build directory not found: $BUILD_DIR" >&2
    exit 1
fi

echo "================================================"
echo "  DinoX Windows Distribution Builder"
echo "================================================"
echo ""

# Always build from an empty distribution tree.  A failed packaging run leaves
# no dist/dinox.exe behind, so an older binary cannot be mistaken for the new
# test build.
echo "[1/8] Creating a fresh distribution tree..."
rm -rf dist
trap finish_dist_rebuild EXIT

mkdir -p dist/bin
mkdir -p dist/lib
mkdir -p dist/plugins
mkdir -p dist/share/icons
mkdir -p dist/ssl/certs

# No file from an older distribution is reused.
echo "[2/8] Initializing runtime directories..."
mkdir -p dist/plugins dist/lib/gstreamer-1.0

# ============================================
# Main executable (must be in dist/ root)
# ============================================
echo "[3/8] Copying main executable..."
cp "$BUILD_DIR/main/dinox.exe" dist/
{
    echo "source_commit=$(git rev-parse HEAD)"
    echo "source_branch=$(git branch --show-current)"
    if [ -n "$(git status --porcelain)" ]; then
        echo "source_dirty=true"
    else
        echo "source_dirty=false"
    fi
} > dist/build-info.txt

# Remove legacy launcher script if present (dinox.exe handles everything now;
# keeping the .bat file caused confusion because it opens a CMD window).
rm -f dist/dinox.bat 2>/dev/null || true

# ============================================
# Core DLLs (must be next to dinox.exe for Windows DLL loading)
# ============================================
echo "[4/8] Copying Core DLLs..."
cp "$BUILD_DIR/libdino/libdino-0.dll" dist/
cp "$BUILD_DIR/xmpp-vala/libxmpp-vala-0.dll" dist/
cp "$BUILD_DIR/qlite/libqlite-0.dll" dist/
cp "$BUILD_DIR/crypto-vala/libcrypto-vala-0.dll" dist/
echo "  [OK] libdino-0.dll, libxmpp-vala-0.dll, libqlite-0.dll, libcrypto-vala-0.dll"

# ============================================
# System DLLs from MSYS2 (required for standalone Windows execution)
# ============================================
echo "[4b/8] Copying MSYS2 system DLLs..."
MINGW_BIN="/mingw64/bin"
GOOGLE_WEBRTC_RELEASE=false
if find "$BUILD_DIR/plugins/google-webrtc" -maxdepth 1 -name 'google-webrtc.dll' -type f 2>/dev/null | grep . >/dev/null; then
    GOOGLE_WEBRTC_RELEASE=true
fi
if [ "$GOOGLE_WEBRTC_RELEASE" = false ]; then
    echo "  [ERROR] Production Windows dist requires plugins/google-webrtc/google-webrtc.dll."
    echo "          Use scripts/build-windows-dist.sh; legacy RTP packages are not supported."
    exit 1
fi

# GTK4 and Adwaita
SYSTEM_DLLS=(
    # GTK4 core
    "libgtk-4-1.dll"
    "libadwaita-1-0.dll"
    "libgdk_pixbuf-2.0-0.dll"
    "libcairo-2.dll"
    "libcairo-gobject-2.dll"
    "libcairo-script-interpreter-2.dll"
    
    # Pango text rendering deps
    "libpango-1.0-0.dll"
    "libpangocairo-1.0-0.dll"
    "libpangowin32-1.0-0.dll"
    "libpangoft2-1.0-0.dll"
    "libthai-0.dll"
    "libdatrie-1.dll"
    
    # GLib family
    "libglib-2.0-0.dll"
    "libgobject-2.0-0.dll"
    "libgio-2.0-0.dll"
    "libgmodule-2.0-0.dll"
    "libgthread-2.0-0.dll"
    
    # Image format support
    "libpng16-16.dll"
    "libjpeg-8.dll"
    "libtiff-6.dll"
    "libwebp-7.dll"
    "libwebpdemux-2.dll"
    "libwebpmux-3.dll"
    "libheif.dll"
    "libavif-16.dll"
    "libjxl.dll"
    "libjxl_cms.dll"
    "libjxl_threads.dll"
    "librsvg-2-2.dll"
    
    # Graphics
    "libpixman-1-0.dll"
    "libfreetype-6.dll"
    "libfontconfig-1.dll"
    "libharfbuzz-0.dll"
    "libharfbuzz-gobject-0.dll"
    "libharfbuzz-subset-0.dll"
    "libfribidi-0.dll"
    "libgraphene-1.0-0.dll"
    "libepoxy-0.dll"
    
    # Compression
    "zlib1.dll"
    "libbz2-1.dll"
    "libbrotlidec.dll"
    "libbrotlicommon.dll"
    "liblzma-5.dll"
    "libzstd.dll"
    
    # Crypto/SSL
    "libssl-3-x64.dll"
    "libcrypto-3-x64.dll"
    "libgcrypt-20.dll"
    "libgpg-error-0.dll"
    "libassuan-0.dll"
    "libnpth-0.dll"
    "libgpgme-11.dll"
    
    # Network
    "libsoup-3.0-0.dll"
    "libnghttp2-14.dll"
    "libpsl-5.dll"
    "libidn2-0.dll"
    "libunistring-5.dll"
    
    # SQLite
    "libsqlite3-0.dll"
    
    # Other dependencies
    "libintl-8.dll"
    "libiconv-2.dll"
    "libpcre2-8-0.dll"
    "libffi-8.dll"
    "libexpat-1.dll"
    "libxml2-2.dll"
    "libsecret-1-0.dll"
    "libdeflate.dll"
    "libjbig-0.dll"
    "libLerc.dll"
    "libgraphite2.dll"
    "liblzo2-2.dll"
    "libsharpyuv-0.dll"
    "libnghttp3-9.dll"
    "libngtcp2-111.dll"
    "libngtcp2_crypto_ossl-0.dll"
    "libssh2-1.dll"
    
    # GStreamer remains for media-file playback/encoding. Live calls use the
    # packaged Google/libwebrtc worker in the production release profile.
    "libgstreamer-1.0-0.dll"
    "libgstbase-1.0-0.dll"
    "libgstaudio-1.0-0.dll"
    "libgstvideo-1.0-0.dll"
    "libgstapp-1.0-0.dll"
    "libgstpbutils-1.0-0.dll"
    "libgstgl-1.0-0.dll"
    "libgstcodecs-1.0-0.dll"
    "libnice-10.dll"
    "liborc-0.4-0.dll"
    
    # Windows-specific
    "libwinpthread-1.dll"
    "libstdc++-6.dll"
    "libgcc_s_seh-1.dll"
    
    # ICU (internationalization - for webkit/soup)
    "libicuuc78.dll"
    "libicuin78.dll"
    "libicudt78.dll"
    
    # Gee (collections library)
    "libgee-0.8-2.dll"
    
    # QREncode
    "libqrencode-4.dll"
    
    # Audio/Video codecs (needed by GStreamer plugins)
    "libopus-0.dll"
    "libopenh264-7.dll"
    "libvpx-1.dll"
    
    # Vorbis/Ogg/FLAC (needed by matroska/WebM audio, voice messages)
    "libvorbis-0.dll"
    "libvorbisenc-2.dll"
    "libvorbisfile-3.dll"
    "libogg-0.dll"
    "libFLAC-12.dll"
    "libmpg123-0.dll"
    
    # Note: FFmpeg DLLs (libavcodec, etc.) are NOT listed here.
    # If mingw-w64-x86_64-ffmpeg is installed, the gst-libav plugin and
    # its FFmpeg deps are picked up automatically by step 4e (auto-detect).
    
    # Signal protocol (not in MSYS2's standard packages, built separately for OMEMO)
    # "libsignal-protocol-c-2.dll"
    
    # SRTPv2 for RTP
    "libsrtp2-1.dll"
    
    # AppStream (dependency of libadwaita/GTK4 on newer MSYS2)
    "libappstream-5.dll"
    "libcurl-4.dll"
    "libxmlb-2.dll"
    "libyaml-0-2.dll"
    
    # Additional GStreamer libs (transitive deps of RTP/video plugins)
    "libgstallocators-1.0-0.dll"
    "libgstd3d11-1.0-0.dll"
    "libgstd3d12-1.0-0.dll"
    "libgstd3dshader-1.0-0.dll"
    "libgstplay-1.0-0.dll"
    "libgstplayer-1.0-0.dll"
    "libgsttag-1.0-0.dll"
    "libgstfft-1.0-0.dll"
    
    # Signal protocol (OMEMO encryption)
    "libomemo-c-0.dll"
    
    # GnuTLS + deps (required by ice plugin / libnice for DTLS)
    "libgnutls-30.dll"
    "libnettle-8.dll"
    "libhogweed-6.dll"
    "libgmp-10.dll"
    "libtasn1-6.dll"
    "libp11-kit-0.dll"
    
    # JSON-GLib (required by tor-manager plugin)
    "libjson-glib-1.0-0.dll"
    
    # MQTT (required by mqtt plugin — pacman -S mingw-w64-x86_64-mosquitto)
    "libmosquitto.dll"
    "libunbound-8.dll"
    "libprotobuf-c-1.dll"
    "libcjson-1.dll"
    
    # Tor async networking (transitive dep of tor.exe)
    # MSYS2 may use either libevent-2-1-7.dll or libevent-7.dll depending on version
    "libevent-2-1-7.dll"
    "libevent_core-2-1-7.dll"
    "libevent_extra-2-1-7.dll"
    "libevent-7.dll"
    "libevent_core-7.dll"
    "libevent_extra-7.dll"
    
    # SQLCipher (if using encrypted DB instead of plain sqlite)
    "libsqlcipher-0.dll"

    # GStreamer media helper DLLs (libgstrtp is required by isomp4/qtdemux for MP4/M4A message playback)
    "libgstrtp-1.0-0.dll"
)

if [ "$GOOGLE_WEBRTC_RELEASE" = false ]; then
    SYSTEM_DLLS+=(
        "libgstsdp-1.0-0.dll"
        "libgstwebrtc-1.0-0.dll"
    )
fi

# DLLs that are optional (statically linked or only present with certain packages)
OPTIONAL_DLLS=(
    "libomemo-c-0.dll"    # statically linked — only exists if built with BUILD_SHARED_LIBS
    "libyaml-0-2.dll"     # only present if mingw-w64-x86_64-libyaml is installed (AppStream dep)
)

DLL_COUNT=0
for dll in "${SYSTEM_DLLS[@]}"; do
    if [ -f "$MINGW_BIN/$dll" ]; then
        cp "$MINGW_BIN/$dll" dist/
        DLL_COUNT=$((DLL_COUNT + 1))
    else
        # Try alternative names (version numbers may differ)
        FOUND=false
        for alt in "$MINGW_BIN"/${dll%%-*}*.dll; do
            if [ -f "$alt" ]; then
                cp "$alt" dist/
                DLL_COUNT=$((DLL_COUNT + 1))
                FOUND=true
                break
            fi
        done
        if [ "$FOUND" = false ]; then
            # Check if this DLL is in the optional list
            IS_OPTIONAL=false
            for opt in "${OPTIONAL_DLLS[@]}"; do
                if [ "$dll" = "$opt" ]; then
                    IS_OPTIONAL=true
                    break
                fi
            done
            if [ "$IS_OPTIONAL" = true ]; then
                echo "  [INFO] Optional, not found: $dll"
            else
                echo "  [WARN] Not found: $dll"
            fi
        fi
    fi
done
echo "  [OK] $DLL_COUNT system DLLs copied"

# Copy GDK-Pixbuf loaders (for image format support)
# MUST copy into dist/lib/gdk-pixbuf-2.0/ (not dist/lib/) so the directory
# structure matches what GDK_PIXBUF_MODULEDIR points to.
if [ -d "/mingw64/lib/gdk-pixbuf-2.0" ]; then
    rm -rf dist/lib/gdk-pixbuf-2.0
    mkdir -p dist/lib/gdk-pixbuf-2.0
    GDK_PIXBUF_LOADER_COUNT=0
    while IFS= read -r -d '' loader; do
        # WMF is not a DinoX runtime format. Excluding it also avoids bundling
        # libwmf's embedded legacy GD/Tcl license stack.
        [ "$(basename "$loader")" = "io-wmf.dll" ] && continue
        loader_relative="${loader#/mingw64/lib/gdk-pixbuf-2.0/}"
        mkdir -p "dist/lib/gdk-pixbuf-2.0/$(dirname "$loader_relative")"
        cp "$loader" "dist/lib/gdk-pixbuf-2.0/$loader_relative"
        GDK_PIXBUF_LOADER_COUNT=$((GDK_PIXBUF_LOADER_COUNT + 1))
    done < <(find /mingw64/lib/gdk-pixbuf-2.0 -type f -name '*.dll' -print0)
    [ "$GDK_PIXBUF_LOADER_COUNT" -gt 0 ] \
        || { echo "  [ERROR] No GDK-Pixbuf runtime loaders found" >&2; exit 1; }
    echo "  [OK] $GDK_PIXBUF_LOADER_COUNT GDK-Pixbuf runtime loaders"
fi

# Copy GIO modules (for GVFS, etc.)
if [ -d "/mingw64/lib/gio" ]; then
    rm -rf dist/lib/gio
    mkdir -p dist/lib/gio
    GIO_MODULE_COUNT=0
    while IFS= read -r -d '' module; do
        module_relative="${module#/mingw64/lib/gio/}"
        mkdir -p "dist/lib/gio/$(dirname "$module_relative")"
        cp "$module" "dist/lib/gio/$module_relative"
        GIO_MODULE_COUNT=$((GIO_MODULE_COUNT + 1))
    done < <(find /mingw64/lib/gio -type f -name '*.dll' -print0)
    # GnuTLS's narrow file API cannot read a CA bundle below a Unicode Windows
    # user directory. Use the pinned, patched GIO module and account for its
    # exact source in windows-license-inventory.py.
    bash "$PROJECT_ROOT/scripts/prepare-windows-tls.sh" --check
    cp "$WINDOWS_VENDOR_ROOT/glib-networking-2.80.1-dinox/lib/gio/modules/libgiognutls.dll" \
        dist/lib/gio/modules/libgiognutls.dll
    if [ -d dist/lib/gio/modules ]; then
        if command -v gio-querymodules >/dev/null 2>&1; then
            gio-querymodules "$(cd dist/lib/gio/modules && pwd -W 2>/dev/null || pwd)"
        elif [ -f /mingw64/lib/gio/modules/giomodule.cache ]; then
            cp /mingw64/lib/gio/modules/giomodule.cache dist/lib/gio/modules/
        else
            echo "  [ERROR] Cannot create the required GIO module cache" >&2
            exit 1
        fi
    fi
    echo "  [OK] $GIO_MODULE_COUNT GIO runtime modules"
fi

# Copy GStreamer plugins (for audio/video)
if [ -d "/mingw64/lib/gstreamer-1.0" ]; then
    # Clean old plugins to avoid stale DLLs from previous runs
    rm -rf dist/lib/gstreamer-1.0
    mkdir -p dist/lib/gstreamer-1.0
    # Only copy essential plugins to keep size manageable
    # Note: wasapi2 replaces both old wasapi and directsound on Windows 10+
    GST_PLUGIN_NAMES="coreelements audioconvert audioresample audiorate volume autodetect \
                  wasapi2 \
                  opus vpx openh264 x264 voaac app audioparsers \
                  playback typefindfunctions videoconvert videoscale videofilter \
                  videorate videoparsersbad d3d11 d3d12 mediafoundation \
                  isomp4 audiofx level libav \
                  videotestsrc audiotestsrc audiomixer \
                  matroska ogg vorbis flac wavparse wavenc gdkpixbuf \
                  mpg123 alaw mulaw gio"
    if [ "$GOOGLE_WEBRTC_RELEASE" = false ]; then
        GST_PLUGIN_NAMES="$GST_PLUGIN_NAMES rtp rtpmanager srtp dtls nice webrtc"
    fi
    for plugin in $GST_PLUGIN_NAMES; do
        for f in /mingw64/lib/gstreamer-1.0/*${plugin}*.dll; do
            [ -f "$f" ] && cp "$f" dist/lib/gstreamer-1.0/
        done
    done
    echo "  [OK] GStreamer plugins"
fi

# ============================================
# Plugins (loaded dynamically from plugins/)
# Copy BEFORE auto-detect so their dependencies get resolved too
# ============================================
echo "[4d/8] Copying DinoX Plugins..."
find "$BUILD_DIR/plugins" -name "*.dll" -exec cp {} dist/plugins/ \;
echo "  [OK] $(ls dist/plugins/*.dll 2>/dev/null | wc -l) plugins copied"

# The Windows libwebrtc runtime is built with the native MSVC/clang-cl ABI and
# consumed by the MinGW-built DinoX plugin only through its stable C ABI.
# Keep the wrapper DLL and worker executable next to each other so the wrapper
# can discover the worker without PATH or registry state.
if [ -f "dist/plugins/google-webrtc.dll" ]; then
    WEBRTC_RUNTIME_ROOT="${DINOX_GOOGLE_WEBRTC_RUNTIME_ROOT:-}"
    if [ -z "$WEBRTC_RUNTIME_ROOT" ]; then
        echo "  [ERROR] google-webrtc.dll was built, but DINOX_GOOGLE_WEBRTC_RUNTIME_ROOT is unset."
        echo "          Point it at the validated Google/libwebrtc Windows runtime artifact."
        exit 1
    fi
    scripts/check-libwebrtc-windows-runtime.sh "$WEBRTC_RUNTIME_ROOT" 40 10 6
    cp "$WEBRTC_RUNTIME_ROOT/bin/dinox-google-webrtc.dll" dist/
    cp "$WEBRTC_RUNTIME_ROOT/bin/dinox-webrtc-worker.exe" dist/
    cp "$WEBRTC_RUNTIME_ROOT/bin/dinox-vision-worker.exe" \
       "$WEBRTC_RUNTIME_ROOT/bin/dinox-vision-runtime-manifest.json" \
       "$WEBRTC_RUNTIME_ROOT/bin/dinox-vision-SHA256SUMS" dist/
    # Preserve the producer's flat package namespace and exact original files.
    rm -rf dist/dinox-vision-models dist/dinox-vision-licenses
    cp -R "$WEBRTC_RUNTIME_ROOT/bin/dinox-vision-models" \
          "$WEBRTC_RUNTIME_ROOT/bin/dinox-vision-licenses" dist/
    python3 scripts/check-vision-runtime.py --base dist --platform windows
    mkdir -p dist/share/licenses/dinox/google-libwebrtc
    cp "$WEBRTC_RUNTIME_ROOT/LICENSE" \
       "$WEBRTC_RUNTIME_ROOT/LICENSE.md" \
       "$WEBRTC_RUNTIME_ROOT/PATENTS" \
       "$WEBRTC_RUNTIME_ROOT/manifest.json" \
       dist/share/licenses/dinox/google-libwebrtc/
    if [ -f "$WEBRTC_RUNTIME_ROOT/WEBRTC-CODECS.json" ]; then
        cp "$WEBRTC_RUNTIME_ROOT/WEBRTC-CODECS.json" \
           "$WEBRTC_RUNTIME_ROOT/WEBRTC-GN-ARGS.gn" \
           dist/share/licenses/dinox/google-libwebrtc/
        cp scripts/libwebrtc-windows-runtime/CODEC-SOURCES.md \
           dist/share/licenses/dinox/google-libwebrtc/
    fi
    if [ -f "$WEBRTC_RUNTIME_ROOT/FFMPEG-WINDOWS-HARDWARE.json" ]; then
        # Unique names keep the minimal call codecs out of GStreamer's full
        # FFmpeg dependency closure used by media-message playback.
        cp "$WEBRTC_RUNTIME_ROOT/bin/avcodec-dinox-hw-62.dll" \
           "$WEBRTC_RUNTIME_ROOT/bin/avutil-dinox-hw-60.dll" dist/
        cp "$WEBRTC_RUNTIME_ROOT/FFMPEG-LICENSE" \
           "$WEBRTC_RUNTIME_ROOT/FFMPEG-WINDOWS-HARDWARE.json" \
           dist/share/licenses/dinox/google-libwebrtc/
        mkdir -p dist/share/licenses/dinox/google-libwebrtc/sources
        cp "$WEBRTC_RUNTIME_ROOT/sources/ffmpeg-mf-dynamic-bitrate.patch" \
           dist/share/licenses/dinox/google-libwebrtc/sources/
    fi
    echo "  [OK] Google/libwebrtc wrapper, workers, vision models and notices copied"
fi

# Clean up any stale core DLLs that may have landed in plugins/ from earlier builds.
# These are NOT plugins and would cause "register_plugin not found" errors.
for core_dll in libdino-0.dll libxmpp-vala-0.dll libqlite-0.dll libcrypto-vala-0.dll; do
    rm -f "dist/plugins/$core_dll" 2>/dev/null
done

# ============================================
# Translation files (.mo) for in-app language switching
# Without these, gettext cannot find translations and the app stays English.
# Structure: dist/locale/<lang>/LC_MESSAGES/<package>.mo
# ============================================
echo "[4e/8] Copying translation files..."
MO_COUNT=0
copy_expected_catalog_set \
    "$PROJECT_ROOT/main/po/LINGUAS" \
    "$BUILD_DIR/main/po" \
    dino \
    "$PROJECT_ROOT/dist/locale"
MO_COUNT=$((MO_COUNT + CATALOG_SET_COUNT))
copy_expected_catalog_set \
    "$PROJECT_ROOT/plugins/omemo/po/LINGUAS" \
    "$BUILD_DIR/plugins/omemo/po" \
    dino-omemo \
    "$PROJECT_ROOT/dist/locale"
MO_COUNT=$((MO_COUNT + CATALOG_SET_COUNT))
copy_expected_catalog_set \
    "$PROJECT_ROOT/plugins/openpgp/po/LINGUAS" \
    "$BUILD_DIR/plugins/openpgp/po" \
    dino-openpgp \
    "$PROJECT_ROOT/dist/locale"
MO_COUNT=$((MO_COUNT + CATALOG_SET_COUNT))
[ "$MO_COUNT" -gt 0 ] || {
    echo "  [ERROR] No DinoX translation files were copied" >&2
    exit 1
}
echo "  [OK] $MO_COUNT translation files copied"

# GTK/libadwaita/GLib provide their own context menus and stock UI strings
# (e.g. Cut/Copy/Paste/Delete). Bundle their translations separately under
# share/locale so GTK's gettext domains can find them.
copy_runtime_catalogs \
    /mingw64/share/locale \
    "$PROJECT_ROOT/dist/share/locale"
echo "  [OK] $RUNTIME_CATALOG_COUNT GTK/runtime translation files copied"

# ============================================
# AUTO-DETECT missing DLL dependencies (recursive!)
# This scans ALL DLLs/EXEs in dist/ using objdump to find their
# imports, then copies any missing DLL from MSYS2's /mingw64/bin/.
# Repeats until no new DLLs are discovered (transitive resolution).
# This eliminates the need to manually track every dependency.
# ============================================
echo "[4e/8] Auto-detecting missing DLL dependencies..."
AUTO_COUNT=0
PASS=0
while true; do
    PASS=$((PASS + 1))
    FOUND_NEW=false
    
    # Collect all DLL imports from everything in dist/ including subdirs
    ALL_DEPS=$(find dist -type f \( -iname '*.exe' -o -iname '*.dll' \) -print0 \
        | xargs -0 -r objdump -p 2>/dev/null \
        | grep "DLL Name:" | awk '{print $3}' | sort -u || true)
    
    for dep_name in $ALL_DEPS; do
        # Skip if already in dist/
        [ -f "dist/$dep_name" ] && continue
        
        # Copy from MSYS2 if available (system DLLs like kernel32.dll
        # won't be in /mingw64/bin/ so they're skipped automatically)
        if [ -f "$MINGW_BIN/$dep_name" ]; then
            cp "$MINGW_BIN/$dep_name" dist/
            echo "  + Pass $PASS: $dep_name"
            AUTO_COUNT=$((AUTO_COUNT + 1))
            FOUND_NEW=true
        fi
    done
    
    # Stop when no new DLLs were found
    if [ "$FOUND_NEW" = false ]; then
        break
    fi
    
    # Safety: max 10 passes to avoid infinite loops
    if [ $PASS -ge 10 ]; then
        echo "  [WARN] Stopped after $PASS passes (safety limit)"
        break
    fi
done
if [ $AUTO_COUNT -gt 0 ]; then
    echo "  [OK] Auto-copied $AUTO_COUNT additional DLLs in $PASS passes"
else
    echo "  [OK] No missing dependencies detected"
fi

# ============================================
# Helper executables (all in bin/)
# ============================================
echo "[5/8] Copying helper executables to bin/..."

# The backup archive helper is built from DinoX sources so Unicode archive
# entries do not depend on the system tar's narrow-path implementation.
if [ ! -s "$BUILD_DIR/main/dinox-backup-tar.exe" ]; then
    fail "Required DinoX backup archive helper was not built: $BUILD_DIR/main/dinox-backup-tar.exe"
    exit 1
fi
cp "$BUILD_DIR/main/dinox-backup-tar.exe" dist/bin/
python3 scripts/embed-windows-utf8-manifest.py check dist/bin/dinox-backup-tar.exe
echo "  [OK] dinox-backup-tar.exe (native Unicode archive helper)"

# GnuPG executables (for OpenPGP and encrypted backups).  These are one
# runtime unit: accepting a package without any one of them produces failures
# only after the user imports, fetches or shuts down a keyring.
for helper in gpg.exe gpg-agent.exe gpgconf.exe gpg-connect-agent.exe dirmngr.exe; do
    if [ ! -f "/mingw64/bin/$helper" ]; then
        echo "  [ERROR] Required bundled GnuPG helper not found: $helper"
        exit 1
    fi
    cp "/mingw64/bin/$helper" dist/bin/
    echo "  [OK] $helper"
done

if [ -f "/mingw64/bin/pinentry-w32.exe" ]; then
    PINENTRY_PATH="/mingw64/bin/pinentry-w32.exe"
else
    echo "  [ERROR] Required bundled GnuPG helper not found: pinentry-w32.exe"
    exit 1
fi
cp "$PINENTRY_PATH" dist/bin/
echo "  [OK] pinentry-w32.exe"

# GLib subprocess helpers (needed by GSubprocess on Windows). These must be
# next to the bundled GLib DLLs in dist/ root; otherwise every DinoX
# new_subprocess() call can fail even when the target executable exists.
for helper in gspawn-win64-helper.exe gspawn-win64-helper-console.exe; do
    if [ -f "/mingw64/bin/$helper" ]; then
        cp "/mingw64/bin/$helper" dist/
        cp "/mingw64/bin/$helper" dist/bin/
        echo "  [OK] $helper (bin/ + root)"
    else
        echo "  [ERROR] $helper not found; Windows subprocess spawning will not work."
        exit 1
    fi
done

# GPGME spawn helper (needed by GPGME library - MUST be next to exe or in PATH)
if [ ! -f "/mingw64/bin/gpgme-w32spawn.exe" ]; then
    echo "  [ERROR] Required GPGME helper not found: gpgme-w32spawn.exe"
    exit 1
fi
cp /mingw64/bin/gpgme-w32spawn.exe dist/bin/
# ALSO copy to dist/ root as GPGME looks there first.
cp /mingw64/bin/gpgme-w32spawn.exe dist/
echo "  [OK] gpgme-w32spawn.exe (bin/ + root)"

echo "[5b/8] Auto-detecting helper executable DLL dependencies..."
HELPER_AUTO_COUNT=0
PASS=1
while true; do
    FOUND_NEW=false
    HELPER_DEPS=$(objdump -p dist/bin/*.exe dist/gpgme-w32spawn.exe dist/*.dll 2>/dev/null \
        | grep "DLL Name:" | awk '{print $3}' | sort -u || true)

    for dep_name in $HELPER_DEPS; do
        [ -f "dist/$dep_name" ] && continue
        if [ -f "$MINGW_BIN/$dep_name" ]; then
            cp "$MINGW_BIN/$dep_name" dist/
            echo "  + Helper pass $PASS: $dep_name"
            HELPER_AUTO_COUNT=$((HELPER_AUTO_COUNT + 1))
            FOUND_NEW=true
        fi
    done

    if [ "$FOUND_NEW" = false ]; then
        break
    fi
    if [ $PASS -ge 10 ]; then
        echo "  [WARN] Stopped helper dependency scan after $PASS passes (safety limit)"
        break
    fi
    PASS=$((PASS + 1))
done
if [ $HELPER_AUTO_COUNT -gt 0 ]; then
    echo "  [OK] Auto-copied $HELPER_AUTO_COUNT helper DLL dependencies"
else
    echo "  [OK] No missing helper dependencies detected"
fi

if command -v ldd >/dev/null 2>&1; then
    for helper in dist/bin/gpg.exe dist/bin/gpg-agent.exe dist/bin/gpgconf.exe dist/bin/gpg-connect-agent.exe dist/bin/dirmngr.exe dist/bin/gpgme-w32spawn.exe dist/gspawn-win64-helper.exe dist/gspawn-win64-helper-console.exe; do
        if [ -f "$helper" ]; then
            missing="$(ldd "$helper" 2>/dev/null | grep -i "not found" || true)"
            if [ -n "$missing" ]; then
                echo "  [ERROR] Missing DLLs for $helper:"
                echo "$missing"
                exit 1
            fi
        fi
    done
fi

# OpenSSL (for backup encryption - simpler than GPG, no agent needed)
if [ -f "/mingw64/bin/openssl.exe" ]; then
    cp /mingw64/bin/openssl.exe dist/bin/
    python3 scripts/embed-windows-utf8-manifest.py embed \
        dist/bin/openssl.exe main/data/dinox.exe.manifest
    python3 scripts/embed-windows-utf8-manifest.py check dist/bin/openssl.exe
    echo "  [OK] openssl.exe (UTF-8 process manifest)"
else
    echo "  [ERROR] Native /mingw64/bin/openssl.exe not found; encrypted backups will not work."
    exit 1
fi

# Tor - MUST use MinGW64 native build, NOT the MSYS2/Cygwin version.
# The complete portable distribution always includes the Tor runtime.
if ! TOR_PATH="$(locate_tor_binary)"; then
    echo "  [ERROR] Native /mingw64/bin/tor.exe is required for the complete Windows distribution." >&2
    echo "          Install the validated mingw-w64-x86_64-tor package before building." >&2
    exit 1
fi
cp "$TOR_PATH" dist/bin/tor.exe
echo "  [OK] tor.exe (mingw64 native)"
require_tor_version dist/bin/tor.exe
python3 scripts/embed-windows-utf8-manifest.py embed \
    dist/bin/tor.exe main/data/dinox.exe.manifest
python3 scripts/embed-windows-utf8-manifest.py check dist/bin/tor.exe
echo "  [OK] tor.exe UTF-8 process manifest"

# lyrebird (Tor pluggable transport: obfs4 + WebTunnel) — preferred over obfs4proxy
if ! LYREBIRD_PATH="$(locate_lyrebird_binary)"; then
    if [ -n "${DINOX_LYREBIRD_PATH:-}" ]; then
        echo "  [ERROR] DINOX_LYREBIRD_PATH does not point to a file: $DINOX_LYREBIRD_PATH" >&2
    else
        echo "  [ERROR] Lyrebird $LYREBIRD_REQUIRED_VERSION is required for the complete Windows distribution." >&2
        echo "          Set DINOX_LYREBIRD_PATH to the validated lyrebird.exe." >&2
    fi
    exit 1
fi
cp "$LYREBIRD_PATH" dist/bin/lyrebird.exe
echo "  [OK] lyrebird.exe (supports obfs4 + WebTunnel)"
require_lyrebird_version dist/bin/lyrebird.exe

# Lyrebird is required above and provides the supported obfs4 implementation.
# Do not opportunistically package an unrelated obfs4proxy.exe from HOME or
# MSYS2: that would make the portable component and license set host-dependent.

# Tor GeoIP data files (needed for bridge/country selection)
GEOIP_SRC=""
for gp in /mingw64/share/tor/geoip C:/msys64/mingw64/share/tor/geoip; do
    if [ -f "$gp" ]; then
        GEOIP_SRC="$(dirname "$gp")"
        break
    fi
done
if [ -n "$GEOIP_SRC" ]; then
    mkdir -p dist/share/tor
    cp "$GEOIP_SRC/geoip" dist/share/tor/ 2>/dev/null && echo "  [OK] geoip"
    cp "$GEOIP_SRC/geoip6" dist/share/tor/ 2>/dev/null && echo "  [OK] geoip6"
else
    echo "  [WARN] GeoIP files not found. Tor may have trouble selecting bridges."
fi

# ============================================
# Resources (share/)
# ============================================
echo "[6/8] Copying resources..."

# CA Certificates (needed for TLS)
CA_BUNDLE=""
for ca_path in /mingw64/ssl/certs/ca-bundle.crt \
               /mingw64/etc/ssl/certs/ca-bundle.crt \
               /etc/ssl/certs/ca-bundle.crt \
               /usr/ssl/certs/ca-bundle.crt \
               /mingw64/ssl/cert.pem; do
    if [ -f "$ca_path" ]; then
        CA_BUNDLE="$ca_path"
        break
    fi
done
if [ -n "$CA_BUNDLE" ]; then
    cp "$CA_BUNDLE" dist/ssl/certs/ca-bundle.crt
    cp "$CA_BUNDLE" dist/ca-bundle.crt
    echo "  [OK] CA certificates (from $CA_BUNDLE)"
else
    echo "  [WARN] No CA certificate bundle found! TLS connections may fail."
    echo "         Install: pacman -S ca-certificates"
fi

# GTK4 schemas (needed for settings)
if [ -d "/mingw64/share/glib-2.0/schemas" ]; then
    mkdir -p dist/share/glib-2.0/schemas
    cp /mingw64/share/glib-2.0/schemas/gschemas.compiled dist/share/glib-2.0/schemas/ 2>/dev/null || true
    cp /mingw64/share/glib-2.0/schemas/*.xml dist/share/glib-2.0/schemas/ 2>/dev/null || true
    echo "  [OK] GLib schemas"
fi

# Adwaita icons (needed for GTK4/libadwaita UI)
if [ -d "/mingw64/share/icons/Adwaita" ]; then
    mkdir -p dist/share/icons
    cp -r /mingw64/share/icons/Adwaita dist/share/icons/
    echo "  [OK] Adwaita icons"
fi

# UI fonts. Newer GTK/libadwaita asks for Adwaita Sans/Mono, but MSYS2
# deployments commonly provide Cantarell and Source Code Pro instead.
copied_ui_fonts=0
for font_dir in \
    /mingw64/share/fonts/adwaita \
    /mingw64/share/fonts/Adwaita \
    /mingw64/share/fonts/cantarell \
    /mingw64/share/fonts/Cantarell \
    /mingw64/share/fonts/adobe-source-code-pro \
    /mingw64/share/fonts/TTF
do
    if [ -d "$font_dir" ]; then
        mkdir -p "dist/share/fonts/$(basename "$font_dir")"
        cp -r "$font_dir"/. "dist/share/fonts/$(basename "$font_dir")/"
        copied_ui_fonts=1
    fi
done
if [ "$copied_ui_fonts" -eq 1 ]; then
    echo "  [OK] UI fonts"
else
    echo "  [WARN] UI fonts not found in MSYS2 prefix"
fi

# Fontconfig configuration (so bundled fonts are found)
mkdir -p dist/etc/fonts
if [ -d "/mingw64/etc/fonts" ]; then
    cp -r /mingw64/etc/fonts/* dist/etc/fonts/
    echo "  [OK] Fontconfig config copied from MSYS2"
fi
# Generate a proper fonts.conf that maps generic families to Windows fonts.
# Without this, fontconfig's "Sans" resolves to a random font (often
# "Microsoft Sans Serif" which looks terrible with freetype).
# This also ensures our bundled fonts dir and Windows system fonts are scanned.
mkdir -p dist/etc/fonts/conf.d
cat > dist/etc/fonts/fonts.conf <<'FCEOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>

  <!-- Font directories -->
  <dir>WINDOWSFONTDIR</dir>
  <dir prefix="relative">../share/fonts</dir>

  <!-- Cache directory -->
  <cachedir>LOCAL_APPDATA_FONTCONFIG_CACHE</cachedir>
  <cachedir prefix="xdg">fontconfig</cachedir>

  <!-- Map generic families to Windows system fonts -->
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>Segoe UI</family>
      <family>Arial</family>
      <family>Noto Sans</family>
    </prefer>
  </alias>

  <alias>
    <family>Sans</family>
    <prefer>
      <family>Segoe UI</family>
      <family>Arial</family>
    </prefer>
  </alias>

  <alias>
    <family>serif</family>
    <prefer>
      <family>Times New Roman</family>
      <family>Georgia</family>
      <family>Noto Serif</family>
    </prefer>
  </alias>

  <alias>
    <family>monospace</family>
    <prefer>
      <family>Consolas</family>
      <family>Cascadia Mono</family>
      <family>Courier New</family>
    </prefer>
  </alias>

  <alias>
    <family>Adwaita Sans</family>
    <prefer>
      <family>Segoe UI</family>
      <family>Cantarell</family>
      <family>Arial</family>
    </prefer>
  </alias>

  <alias>
    <family>Adwaita Mono</family>
    <prefer>
      <family>Source Code Pro</family>
      <family>Consolas</family>
      <family>Cascadia Mono</family>
      <family>DejaVu Sans Mono</family>
      <family>Courier New</family>
    </prefer>
  </alias>

  <alias>
    <family>system-ui</family>
    <prefer>
      <family>Segoe UI</family>
    </prefer>
  </alias>

  <!-- Default rendering: slight hinting + subpixel antialiasing -->
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
  </match>

  <!-- Include additional conf files -->
  <include ignore_missing="yes" prefix="relative">conf.d</include>
  <include ignore_missing="yes" prefix="relative">local.conf</include>

</fontconfig>
FCEOF
echo "  [OK] Fontconfig fonts.conf created (Windows font aliases)"

# Keep local.conf as an override for bundled font paths
cat > dist/etc/fonts/local.conf <<'FCEOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <!-- Bundled DinoX fonts -->
  <dir prefix="relative">../share/fonts</dir>
  <dir>WINDOWSFONTDIR</dir>
</fontconfig>
FCEOF
echo "  [OK] Fontconfig local.conf created"

# Hicolor icons (fallback icon theme)
if [ -d "/mingw64/share/icons/hicolor" ]; then
    cp -r /mingw64/share/icons/hicolor dist/share/icons/
    echo "  [OK] Hicolor icons"
fi

# GTK4 settings — generate custom settings.ini for Windows.
# The MSYS2 default has no font rendering or decoration config.  GTK reads
# settings from XDG config directories, while older packaged DinoX builds also
# carried the file in share/gtk-4.0; keep both locations in sync.
mkdir -p dist/etc/gtk-4.0 dist/share/gtk-4.0
cat > dist/etc/gtk-4.0/settings.ini <<'GTKEOF'
[Settings]
gtk-font-name=Segoe UI 11
gtk-hint-font-metrics=1
gtk-decoration-layout=close,minimize,maximize:
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintslight
gtk-xft-rgba=rgb
GTKEOF
cp dist/etc/gtk-4.0/settings.ini dist/share/gtk-4.0/settings.ini
echo "  [OK] GTK settings (font, hinting, decoration layout)"

# Pixbuf loader template — the runtime replaces the marker with the actual
# extracted DinoX directory and writes the materialized cache below LOCALAPPDATA.
if [ -d "dist/lib/gdk-pixbuf-2.0/2.10.0/loaders" ]; then
    if command -v gdk-pixbuf-query-loaders >/dev/null 2>&1; then
        create_pixbuf_loader_cache \
            "/mingw64/lib/gdk-pixbuf-2.0/2.10.0/loaders" \
            "dist/lib/gdk-pixbuf-2.0/2.10.0/loaders" \
            "dist/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
        echo "  [OK] Pixbuf loader cache template (portable marker)"
    else
        echo "  [ERROR] gdk-pixbuf-query-loaders is required" >&2
        exit 1
    fi
fi

# Application icons — copy image files, NOT index.theme!
# CRITICAL: The system hicolor index.theme (copied above) lists ALL standard
# directories (scalable/actions, scalable/status, scalable/devices, etc.).
# The project's index.theme only lists */apps and would BREAK icon discovery
# for all custom dino-* and system icons in other categories.
if [ -d "main/data/icons/hicolor" ]; then
    for size_dir in main/data/icons/hicolor/*/; do
        [ -d "$size_dir" ] || continue
        size=$(basename "$size_dir")
        for cat_dir in "$size_dir"*/; do
            [ -d "$cat_dir" ] || continue
            cat=$(basename "$cat_dir")
            mkdir -p "dist/share/icons/hicolor/$size/$cat"
            cp "$cat_dir"* "dist/share/icons/hicolor/$size/$cat/" 2>/dev/null || true
        done
    done
    echo "  [OK] DinoX app icons (system index.theme preserved)"
fi

# Custom symbolic icons (dino-*, small-x-*, check-plain-*)
# These are also embedded in the GResource, but installing them to the hicolor
# theme on the filesystem ensures they are found even if GTK4's automatic
# resource_base_path icon discovery fails (common on Windows).
if [ -d "main/data/icons/scalable" ]; then
    for subdir in actions devices mimetypes status; do
        src="main/data/icons/scalable/$subdir"
        if [ -d "$src" ]; then
            mkdir -p "dist/share/icons/hicolor/scalable/$subdir"
            cp "$src"/*.svg "dist/share/icons/hicolor/scalable/$subdir/"
        fi
    done
    echo "  [OK] DinoX custom symbolic icons (hicolor fallback)"
fi

# Remove stale GTK3 icon-theme.cache files — these cause GTK4 to skip
# scanning directories for new icons on some systems.
find dist/share/icons -name 'icon-theme.cache' -delete 2>/dev/null || true

# ============================================
# Pre-generate GStreamer plugin registry cache
# Without this, the first start has to load+inspect every plugin DLL
# (~39 DLLs) which takes 30-60+ seconds on Windows.
# The registry is a binary cache of plugin capabilities (elements,
# formats, codecs). With a pre-built registry, Gst.init() just reads
# the cache file → start in <1 second.
# ============================================
echo "[6b/8] Pre-generating GStreamer registry cache..."
DIST_ABS="$(cd dist && pwd -W 2>/dev/null || pwd)"
DIST_POSIX="$(cd dist && pwd)"
GST_DIR="$DIST_ABS/lib/gstreamer-1.0"
GST_REG="$GST_DIR/registry.bin"
GST_INSPECT_TIMEOUT_SECONDS=90
GST_INSPECT_TIMEOUT_AVAILABLE=false
GST_INSPECT_CMD=(gst-inspect-1.0)
if command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1; then
    GST_INSPECT_CMD=(timeout --kill-after=5s "${GST_INSPECT_TIMEOUT_SECONDS}s" gst-inspect-1.0)
    GST_INSPECT_TIMEOUT_AVAILABLE=true
fi
if [ -d "dist/lib/gstreamer-1.0" ] && command -v gst-inspect-1.0 >/dev/null 2>&1; then
    if ! PATH="$DIST_POSIX:$PATH" \
        GST_PLUGIN_PATH="$GST_DIR" \
        GST_PLUGIN_SYSTEM_PATH="" \
        GST_REGISTRY="$GST_REG" \
        GST_REGISTRY_FORK=no \
        "${GST_INSPECT_CMD[@]}" >/dev/null 2>&1; then
        echo "  [WARN] gst-inspect-1.0 failed or timed out — registry will be built on first start"
    fi
    if [ -f "$GST_REG" ]; then
        REG_SIZE=$(du -h "$GST_REG" 2>/dev/null | cut -f1)
        echo "  [OK] Registry cache created ($REG_SIZE)"
    else
        echo "  [WARN] gst-inspect-1.0 ran but no registry file was created"
    fi
else
    echo "  [SKIP] gst-inspect-1.0 not found — registry will be built on first start"
fi

if [ "$GOOGLE_WEBRTC_RELEASE" = true ]; then
    for required in \
        dist/plugins/google-webrtc.dll \
        dist/dinox-google-webrtc.dll \
        dist/dinox-webrtc-worker.exe \
        dist/dinox-vision-worker.exe \
        dist/dinox-vision-models/selfie_segmenter_landscape-v1.tflite \
        dist/dinox-vision-models/blaze_face_short_range-v1.tflite \
        dist/dinox-vision-runtime-manifest.json \
        dist/dinox-vision-SHA256SUMS \
        dist/share/licenses/dinox/google-libwebrtc/manifest.json; do
        if [ ! -s "$required" ]; then
            echo "  [ERROR] Google/libwebrtc release file missing: $required"
            exit 1
        fi
    done
    python3 scripts/check-vision-runtime.py --base dist --platform windows
    if [ -e dist/plugins/rtp.dll ]; then
        echo "  [ERROR] Legacy RTP call plugin was included in a Google/libwebrtc release"
        exit 1
    fi
    if strings dist/plugins/google-webrtc.dll | grep -F 'System ffmpeg was not found' >/dev/null; then
        echo "  [ERROR] Windows google-webrtc.dll contains the Linux system-ffmpeg message writer"
        exit 1
    fi
    if find dist/lib/gstreamer-1.0 -maxdepth 1 -type f \
            \( -iname '*rtp*.dll' -o -iname '*srtp*.dll' -o -iname '*dtls*.dll' \
               -o -iname '*webrtc*.dll' -o -iname '*nice*.dll' \) | grep . >/dev/null; then
        echo "  [ERROR] Legacy GStreamer live-call plugins were included in a Google/libwebrtc release"
        exit 1
    fi
    if ! command -v gst-inspect-1.0 >/dev/null 2>&1; then
        echo "  [ERROR] gst-inspect-1.0 is required for packaged media-message element checks" >&2
        exit 1
    fi
    if [ "$GST_INSPECT_TIMEOUT_AVAILABLE" != true ]; then
        echo "  [ERROR] GNU timeout is required for bounded packaged media-message element checks" >&2
        exit 1
    fi
    for playback_element in \
            playbin qtdemux h264parse avdec_h264 videoconvert fakesink \
            avdec_aac audioconvert audioresample appsink; do
        inspect_status=0
        inspect_output=""
        inspect_output="$(PATH="$DIST_POSIX:$PATH" \
            GST_PLUGIN_PATH="$GST_DIR" \
            GST_PLUGIN_SYSTEM_PATH="" \
            GST_REGISTRY="$GST_REG" \
            GST_REGISTRY_FORK=no \
            "${GST_INSPECT_CMD[@]}" "$playback_element" 2>&1)" \
            || inspect_status=$?
        if [ "$inspect_status" -ne 0 ]; then
            if [ "$inspect_status" -eq 124 ] || [ "$inspect_status" -eq 137 ]; then
                echo "  [ERROR] Timed out after ${GST_INSPECT_TIMEOUT_SECONDS}s while inspecting packaged media-message element: $playback_element" >&2
            else
                echo "  [ERROR] Packaged media-message playback element missing or failed inspection: $playback_element (gst-inspect exit $inspect_status)" >&2
                [ -n "$inspect_output" ] && echo "$inspect_output" >&2
            fi
            exit 1
        fi
    done
    echo "  [OK] Packaged MP4/H.264/AAC media-message playback elements"
    echo "  [OK] Google/libwebrtc is the only packaged live-call engine"
fi

# Resolve the complete dependency closure only after every plugin and helper
# has been copied.  Earlier passes cannot see late additions such as dirmngr,
# Tor, Lyrebird or the native libwebrtc worker.
echo "[7/8] Resolving final DLL dependency closure..."
FINAL_AUTO_COUNT=0
FINAL_PASS=0
while true; do
    FINAL_PASS=$((FINAL_PASS + 1))
    FOUND_NEW=false
    ALL_PE_DEPS="$(find dist -type f \( -iname '*.exe' -o -iname '*.dll' \) -print0 \
        | xargs -0 -r objdump -p 2>/dev/null \
        | grep 'DLL Name:' | awk '{print $3}' | sort -fu || true)"

    for dep_name in $ALL_PE_DEPS; do
        [ -f "dist/$dep_name" ] && continue
        if [ -f "$MINGW_BIN/$dep_name" ]; then
            cp "$MINGW_BIN/$dep_name" dist/
            echo "  + Final pass $FINAL_PASS: $dep_name"
            FINAL_AUTO_COUNT=$((FINAL_AUTO_COUNT + 1))
            FOUND_NEW=true
        fi
    done

    if [ "$FOUND_NEW" = false ]; then
        break
    fi
    if [ "$FINAL_PASS" -ge 10 ]; then
        echo "  [ERROR] Final DLL dependency scan did not converge after $FINAL_PASS passes"
        exit 1
    fi
done
echo "  [OK] Final dependency closure copied $FINAL_AUTO_COUNT additional DLLs"

echo "[7b/8] Staging complete Windows PE license inventory..."
command -v cygpath >/dev/null 2>&1 \
    || { echo "  [ERROR] cygpath is required for Windows license staging" >&2; exit 1; }
python3 scripts/windows-license-inventory.py stage \
    --project "$(cygpath -m "$PROJECT_ROOT")" \
    --dist "$(cygpath -m "$PROJECT_ROOT/dist")" \
    --build "$(cygpath -m "$PROJECT_ROOT/$BUILD_DIR")" \
    --vendor-root "$(cygpath -m "$WINDOWS_VENDOR_ROOT")" \
    --mingw-root "$(cygpath -m /mingw64)" \
    --msys-root "$(cygpath -m /)" \
    --webrtc-root "$(cygpath -m "$WEBRTC_RUNTIME_ROOT")" \
    --tor "$(cygpath -m "$TOR_PATH")" \
    --openssl "$(cygpath -m /mingw64/bin/openssl.exe)" \
    --lyrebird "$(cygpath -m "$LYREBIRD_PATH")"

bash scripts/check-windows-dist.sh dist

# ============================================
# Summary
# ============================================
echo ""
echo "[8/8] Build complete and validated!"
echo ""
echo "Directory structure:"
echo "  dist/"
echo "  |-- dinox.exe              (main application - run this!)"
echo "  |-- *.dll                  (system + core libraries)"
echo "  |-- bin/"
echo "  |   |-- gpg.exe            (OpenPGP encryption)"
echo "  |   |-- gpg-connect-agent.exe (GnuPG agent control)"
echo "  |   |-- dirmngr.exe        (OpenPGP keyserver access)"
echo "  |   |-- openssl.exe        (backup encryption)"
echo "  |   |-- dinox-backup-tar.exe (backup archive creation and extraction)"
echo "  |   |-- tor.exe            (anonymity)"
echo "  |   \-- lyrebird.exe       (obfs4 + WebTunnel bridges)"
echo "  |-- lib/"
echo "  |   |-- gdk-pixbuf-2.0/    (image loaders)"
echo "  |   |-- gio/               (GIO modules)"
echo "  |   \-- gstreamer-1.0/     (audio/video plugins)"
echo "  |-- plugins/"
echo "  |   \-- *.dll              (DinoX feature plugins)"
echo "  |-- share/"
echo "  |   |-- glib-2.0/schemas/  (GSettings)"
echo "  |   |-- icons/             (Adwaita + app icons)"
echo "  |   \-- licenses/dinox/    (complete PE license inventory)"
echo "  \-- ssl/certs/             (CA certificates)"
echo ""
echo "To run: Double-click dinox.exe"
echo ""
