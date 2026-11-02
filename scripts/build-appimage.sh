#!/bin/bash
# ============================================================================
# DinoX AppImage Builder
#
# Builds the official portable Linux package against the DinoX baseline:
# Ubuntu 24.04 / Linux Mint 22 and Debian 13.
#
# Usage: ./scripts/build-appimage.sh
# Output: DinoX-<VERSION>-<ARCH>.AppImage
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/build-appimage-package"
APPDIR="$PROJECT_ROOT/AppDir"
TOOLS_DIR="$PROJECT_ROOT/.appimage-tools"
VERSION=$(cat "$PROJECT_ROOT/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "1.1.8.1")
TOR_REQUIRED_VERSION="0.4.9.12"
LYREBIRD_REQUIRED_VERSION="0.8.1"
GNUPG_REQUIRED_SERIES="2.4"
LICENSE_SOURCE_MAP=""
PROJECT_INSTALL_MAP=""
SOURCE_EXTRACT_DIR=""
CUSTOM_DEPENDENCY_PREFIX="${DINOX_CUSTOM_DEPENDENCY_PREFIX:-/opt/dinox-deps}"
CUSTOM_DEPENDENCY_BINDIR="$CUSTOM_DEPENDENCY_PREFIX/bin"
CUSTOM_DEPENDENCY_LIBDIR="$CUSTOM_DEPENDENCY_PREFIX/lib"
IBUS_COMPAT_PREFIX="$PROJECT_ROOT/.vendor-deps/ibus-compat-appimage"
export DINOX_IBUS_COMPAT_PREFIX="$IBUS_COMPAT_PREFIX"
CANBERRA_RUNTIME_PREFIX="$PROJECT_ROOT/.vendor-deps/canberra-runtime-appimage"
export DINOX_CANBERRA_RUNTIME_PREFIX="$CANBERRA_RUNTIME_PREFIX"
RECORDER_FFMPEG_ROOT="${DINOX_RECORDER_FFMPEG_ROOT:-$CUSTOM_DEPENDENCY_PREFIX/libexec/dinox-recorder-ffmpeg}"
RECORDER_FFMPEG_SOURCE="$RECORDER_FFMPEG_ROOT/bin/ffmpeg"

export PATH="$CUSTOM_DEPENDENCY_BINDIR${PATH:+:$PATH}"
export PKG_CONFIG_PATH="$CUSTOM_DEPENDENCY_LIBDIR/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CMAKE_PREFIX_PATH="$CUSTOM_DEPENDENCY_PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$CUSTOM_DEPENDENCY_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cleanup_downloads() {
    rm -f "$TOOLS_DIR"/appimagetool-*.AppImage.tmp "$TOOLS_DIR"/runtime-*.tmp "$TOOLS_DIR"/runtime-*.sha256.tmp
    rm -f "$TOOLS_DIR"/appimage-source-payloads.* "$TOOLS_DIR"/appimage-source-inventory.*
    rm -f "$TOOLS_DIR"/appimage-source-expected.* "$TOOLS_DIR"/appimage-source-archive.*
    [ -z "$LICENSE_SOURCE_MAP" ] || rm -f "$LICENSE_SOURCE_MAP"
    [ -z "$PROJECT_INSTALL_MAP" ] || rm -f "$PROJECT_INSTALL_MAP"
    [ -z "$SOURCE_EXTRACT_DIR" ] || rm -rf "$SOURCE_EXTRACT_DIR"
}
trap cleanup_downloads EXIT

usage() {
    cat <<EOF
Usage: $0 [-h|--help]

Builds the DinoX AppImage.

This is a package-builder entry point, not a workstation bootstrap command.
Run it only in the verified DinoX Ubuntu 24.04 package-builder image; the
pinned dependencies under /opt/dinox-deps are mandatory.

Required environment:
  DINOX_LIBWEBRTC_RUNTIME_ROOT       Validated compact Linux runtime root

Optional environment:
  APPIMAGE_RUNTIME_FILE              Explicit AppImage runtime path
  APPIMAGE_RUNTIME_SHA256            SHA256 for APPIMAGE_RUNTIME_FILE
  DINOX_RECORDER_FFMPEG_ROOT         Private static recorder ffmpeg prefix

DINOX_LIBWEBRTC_ARTIFACT_ROOT is deliberately not accepted by this release
package entry point. The current Google/libwebrtc runtime and AppImage target
are x86_64 only.
EOF
}

if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage
    exit 0
fi

if [ "$#" -gt 0 ]; then
    echo "Unknown arguments: $*" >&2
    usage >&2
    exit 2
fi

if [ -n "${DINOX_LIBWEBRTC_ARTIFACT_ROOT:-}" ]; then
    echo "FEHLER: DINOX_LIBWEBRTC_ARTIFACT_ROOT wird von Linux-Paketbuilds nicht unterstützt." >&2
    echo "Nutze für Entwicklungs-/Proof-Builds scripts/configure-libwebrtc-wrapper-build.sh --artifact-root und erzeuge daraus zuerst den kompakten Runtime-Root." >&2
    echo "DinoX-AppImage-Releases benötigen ausschließlich DINOX_LIBWEBRTC_RUNTIME_ROOT." >&2
    exit 1
fi
if [ -z "${DINOX_LIBWEBRTC_RUNTIME_ROOT:-}" ]; then
    echo "FEHLER: Für ein DinoX-AppImage-Release ist der validierte Google/libwebrtc-Runtime-Root erforderlich." >&2
    echo "Setze DINOX_LIBWEBRTC_RUNTIME_ROOT." >&2
    exit 1
fi

# ── Architektur erkennen ──────────────────────────────────────────────────────
ARCH="$(uname -m)"
NINJA_ARGS=()
if [ "$ARCH" != "x86_64" ]; then
    echo "Nicht unterstützte Architektur: $ARCH (DinoX-AppImage benötigt derzeit x86_64)" >&2
    exit 1
fi
TRIPLET="x86_64-linux-gnu"
TOOL_ARCH="x86_64"
MESON_ARGS=""

if [ -n "${DINOX_BUILD_JOBS:-${DINOX_CI_JOBS:-}}" ]; then
    DINOX_EFFECTIVE_JOBS="${DINOX_BUILD_JOBS:-${DINOX_CI_JOBS:-}}"
    if ! [[ "$DINOX_EFFECTIVE_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        echo "FEHLER: ungueltiges DinoX Build-Job-Limit: $DINOX_EFFECTIVE_JOBS" >&2
        exit 2
    fi
    NINJA_ARGS=(-j "$DINOX_EFFECTIVE_JOBS")
fi

OUTPUT="DinoX-${VERSION}-${ARCH}.AppImage"

# ANSI colors
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
step() { echo -e "${CYAN}=== $1 ===${NC}"; }
ok()   { echo -e "  ${GREEN}checkmark${NC} $1"; }
warn() { echo -e "  ${YELLOW}warning${NC}  $1"; }
fail() { echo -e "${RED}FEHLER: $1${NC}" >&2; exit 1; }

sha256_matches() {
    local file="$1" expected="$2"
    printf '%s  %s\n' "$expected" "$file" | sha256sum -c - >/dev/null 2>&1
}

verify_sha256() {
    local file="$1" expected="$2" label="$3"
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] \
        || fail "ungültige SHA256-Prüfsumme für $label"
    sha256_matches "$file" "$expected" \
        || fail "SHA256-Prüfsumme für $label stimmt nicht"
    echo "  OK $label SHA256"
}

sha256_from_file() {
    local checksum_file="$1"
    local checksum
    checksum="$(awk 'NR == 1 { print $1 }' "$checksum_file")"
    [[ "$checksum" =~ ^[0-9a-fA-F]{64}$ ]] \
        || fail "ungültige SHA256-Datei: $checksum_file"
    printf '%s\n' "$checksum"
}

safe_license_relative_path() {
    local relative="$1"
    local component

    [ -n "$relative" ] || return 1
    case "$relative" in
        /*|./*|../*|*/../*|*/..|*/./*|*/.|.|..|*//*|*/)
            return 1
            ;;
    esac
    [[ "$relative" != *$'\n'* && "$relative" != *$'\r'* && "$relative" != *$'\t'* ]] \
        || return 1
    while IFS= read -r component; do
        [ -n "$component" ] && [ "$component" != "." ] && [ "$component" != ".." ] \
            || return 1
    done < <(tr '/' '\n' <<< "$relative")
}

is_appimage_source_payload_path() {
    local relative="$1"

    safe_license_relative_path "$relative" || return 1
    case "$relative" in
        corresponding-sources/*)
            case "${relative##*/}" in
                METADATA|SHA256SUMS) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        google-libwebrtc/sources/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

list_appimage_source_payloads() {
    local license_root="$1"
    local path relative

    [ -d "$license_root/corresponding-sources" ] \
        || fail "AppImage corresponding-sources-Verzeichnis fehlt"
    [ -d "$license_root/google-libwebrtc/sources" ] \
        || fail "Google/libwebrtc-Quellverzeichnis fehlt"
    if find \
            "$license_root/corresponding-sources" \
            "$license_root/google-libwebrtc/sources" \
            -type l -print -quit 2>/dev/null | grep . >/dev/null; then
        fail "Source-Payload-Baum enthält einen nicht erlaubten Symlink"
    fi
    while IFS= read -r -d '' path; do
        relative="${path#"$license_root"/}"
        is_appimage_source_payload_path "$relative" \
            || fail "nicht klassifizierbarer Source-Payload-Pfad: $relative"
        printf '%s\n' "$relative"
    done < <(
        find "$license_root/corresponding-sources" -type f \
            ! -name METADATA ! -name SHA256SUMS -print0
        find "$license_root/google-libwebrtc/sources" -type f -print0
    ) | LC_ALL=C sort -u
}

create_source_payload_inventory() {
    local license_root="$1"
    local output="$license_root/SOURCE_PAYLOADS.tsv"
    local paths temporary relative size checksum previous=""
    local LC_ALL=C

    paths="$(mktemp "$TOOLS_DIR/appimage-source-payloads.XXXXXX")"
    temporary="$(mktemp "$TOOLS_DIR/appimage-source-inventory.XXXXXX")"
    list_appimage_source_payloads "$license_root" > "$paths"
    [ -s "$paths" ] || fail "AppImage Source-Payload-Inventar wäre leer"
    grep -q '^corresponding-sources/' "$paths" \
        || fail "corresponding-source Payloads fehlen im Inventar"
    grep -q '^google-libwebrtc/sources/' "$paths" \
        || fail "Google/libwebrtc Source-Payloads fehlen im Inventar"

    printf 'relative_path\tsize\tsha256\n' > "$temporary"
    while IFS= read -r relative; do
        is_appimage_source_payload_path "$relative" \
            || fail "unsicherer Source-Payload-Inventarpfad: $relative"
        if [ -n "$previous" ] && [[ "$relative" < "$previous" || "$relative" = "$previous" ]]; then
            fail "Source-Payload-Inventar ist nicht strikt sortiert: $relative"
        fi
        previous="$relative"
        [ -f "$license_root/$relative" ] && [ ! -L "$license_root/$relative" ] \
            || fail "Source-Payload ist keine reguläre Datei: $relative"
        size="$(stat -c '%s' -- "$license_root/$relative")"
        checksum="$(sha256sum -- "$license_root/$relative" | awk '{ print $1 }')"
        [[ "$size" =~ ^[1-9][0-9]*$ ]] && [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] \
            || fail "ungültige Source-Payload-Metadaten: $relative"
        printf '%s\t%s\t%s\n' "$relative" "$size" "$checksum" >> "$temporary"
    done < "$paths"
    mv "$temporary" "$output"
    chmod 0644 "$output"
    rm -f "$paths"
}

validate_license_tree_paths() {
    local license_root="$1"
    local path relative

    [ -d "$license_root" ] || fail "AppImage Lizenzbaum fehlt: $license_root"
    if find "$license_root" \( -type l -o ! -type d ! -type f \) -print -quit \
            2>/dev/null | grep . >/dev/null; then
        fail "AppImage Lizenzbaum enthält Symlinks oder Spezialdateien"
    fi
    while IFS= read -r -d '' path; do
        relative="${path#"$license_root"/}"
        safe_license_relative_path "$relative" \
            || fail "unsicherer Pfad im AppImage Lizenzbaum: $relative"
    done < <(find "$license_root" -mindepth 1 -print0)
}

remove_inventoried_source_payloads() {
    local license_root="$1"
    local inventory="$license_root/SOURCE_PAYLOADS.tsv"
    local relative size checksum extra actual_size actual_checksum previous=""
    local LC_ALL=C

    [ -s "$inventory" ] || fail "Source-Payload-Inventar fehlt"
    [ "$(head -1 "$inventory")" = $'relative_path\tsize\tsha256' ] \
        || fail "Source-Payload-Inventarheader ist ungültig"
    while IFS=$'\t' read -r relative size checksum extra; do
        [ -n "$relative" ] && [ -z "${extra:-}" ] \
            && is_appimage_source_payload_path "$relative" \
            || fail "unsicherer oder unvollständiger Source-Payload-Inventareintrag"
        if [ -n "$previous" ] && [[ "$relative" < "$previous" || "$relative" = "$previous" ]]; then
            fail "Source-Payload-Inventar ist nicht strikt sortiert: $relative"
        fi
        previous="$relative"
        [ -f "$license_root/$relative" ] && [ ! -L "$license_root/$relative" ] \
            || fail "inventarierter Source-Payload fehlt vor dem Entfernen: $relative"
        actual_size="$(stat -c '%s' -- "$license_root/$relative")"
        actual_checksum="$(sha256sum -- "$license_root/$relative" | awk '{ print $1 }')"
        [ "$actual_size" = "$size" ] && [ "$actual_checksum" = "$checksum" ] \
            || fail "inventarierter Source-Payload wurde vor dem Entfernen verändert: $relative"
        rm -f -- "$license_root/$relative"
    done < <(tail -n +2 "$inventory")
}

record_distribution_source() {
    local packaged_path="$1"
    local source_path="$2"
    local resolved_source=""
    local relative_path

    [ -n "$LICENSE_SOURCE_MAP" ] || fail "Lizenz-Quellinventar wurde nicht initialisiert"
    case "$packaged_path" in
        "$APPDIR"/*) ;;
        *) fail "Lizenz-Quellpfad liegt außerhalb des AppDir: $packaged_path" ;;
    esac

    # Ubuntu's usrmerge diversions can make `dpkg-query -S /lib/...` succeed
    # with diversion records but no owning package. Record the canonical
    # /usr path so the license stager can resolve and validate the real owner.
    resolved_source="$(readlink -f -- "$source_path" 2>/dev/null || true)"
    [ -n "$resolved_source" ] && [ -e "$resolved_source" ] \
        || fail "Lizenz-Quellpfad ist nicht kanonisierbar: $source_path"

    # These artifacts are built and licensed by ci-build-deps.sh. They are
    # intentionally outside the Debian file/source inventory and are covered
    # by custom-dependencies/ plus the dedicated corresponding-source trees.
    case "$resolved_source" in
        "$CUSTOM_DEPENDENCY_PREFIX"/*)
            return 0
            ;;
        "$APPDIR"/*)
            local appdir_source_relative="${resolved_source#"$APPDIR"/}"
            [ -s "$PROJECT_INSTALL_MAP" ] \
                || fail "Meson-Installationsinventar fehlt für AppDir-interne Quelle: $appdir_source_relative"
            if grep -Fx -- "$appdir_source_relative" "$PROJECT_INSTALL_MAP" >/dev/null; then
                # ldd resolved a package artifact already installed by Meson.
                # Project code and the pinned Google runtime have their own
                # staged license/source trees and must not enter the Debian
                # binary/source package inventory.
                return 0
            fi
            if awk -F '\t' -v target="$appdir_source_relative" -v appdir="$APPDIR/" '
                    $1 == target && index($2, appdir) != 1 { found = 1 }
                    END { exit(found ? 0 : 1) }
                ' "$LICENSE_SOURCE_MAP"; then
                # ldd reused a distribution file copied earlier. Its original
                # external provenance row remains authoritative.
                return 0
            fi
            fail "AppDir-interne ELF-Quelle ist weder Meson-installiert noch zuvor extern inventarisiert: $appdir_source_relative"
            ;;
    esac

    # Do not pre-filter unknown files here. The license stager resolves the
    # exact dpkg owner and fails closed, so a copied /usr/local or otherwise
    # unowned runtime can never disappear silently from release provenance.
    if [ ! -f "$resolved_source" ]; then
        fail "Lizenz-Quellpfad ist keine reguläre Runtime-Datei: $resolved_source"
    fi

    if [ ! -e "$packaged_path" ] && [ ! -L "$packaged_path" ]; then
        fail "aufgezeichnete AppDir-Datei fehlt: $packaged_path"
    fi
    if [ -d "$packaged_path" ]; then
        fail "aufgezeichnete AppDir-Datei ist ein Verzeichnis: $packaged_path"
    fi

    relative_path="${packaged_path#"$APPDIR"/}"
    printf '%s\t%s\n' "$relative_path" "$resolved_source" >> "$LICENSE_SOURCE_MAP"
}

snapshot_project_install_paths() {
    local output="$1"
    local path relative canonical

    : > "$output"
    while IFS= read -r -d '' path; do
        relative="${path#"$APPDIR"/}"
        case "$relative" in
            /*|../*|*/../*|*/..|.|..|*$'\t'*|*$'\n'*)
                fail "unsicherer Meson-Installationspfad im AppDir: $relative"
                ;;
        esac
        if [ -L "$path" ]; then
            canonical="$(readlink -f -- "$path" 2>/dev/null || true)"
            case "$canonical" in
                "$APPDIR"/*) ;;
                *) fail "Meson-Installationssymlink verlässt das AppDir: $relative" ;;
            esac
        fi
        printf '%s\n' "$relative" >> "$output"
    done < <(find "$APPDIR" \( -type f -o -type l \) -print0 | sort -z)
    sort -u -o "$output" "$output"
    [ -s "$output" ] || fail "Meson-Installationsinventar ist leer"
}

# ── Hilfsfunktion: Bibliothek suchen und kopieren ────────────────────────────
copy_lib() {
    local pattern="$1" dest="$2" required="${3:-false}"
    local base="${pattern/\*/}" found=false

    local all_paths
    all_paths=$(
        ldconfig -p 2>/dev/null \
            | grep -F "$base" \
            | awk -F' => ' '{print $2}' \
            | xargs -I{} realpath -e {} 2>/dev/null || true
        find -L /usr/local/lib /usr/lib /lib \
            -maxdepth 3 -name "$pattern" \( -type f -o -type l \) 2>/dev/null || true
    )

    local copied=()
    while IFS= read -r fpath; do
        [ -z "$fpath" ] && continue
        local fname; fname=$(basename "$fpath")
        [[ " ${copied[*]} " == *" $fname "* ]] && continue
        if cp -P "$fpath" "$dest/" 2>/dev/null; then
            copied+=("$fname"); found=true
            record_distribution_source "$dest/$fname" "$fpath"
        fi
    done < <(echo "$all_paths" | sort -u)

    $found && echo "  OK $pattern (${#copied[@]} Dateien)" \
           || { [ "$required" = "true" ] && fail "Pflichtlib '$pattern' nicht gefunden!" \
                                          || echo "  WARNUNG '$pattern' nicht gefunden"; }
}

# Copy release-only dependencies exclusively from their private prefix.
copy_custom_lib() {
    local pattern="$1" dest="$2" required="${3:-false}"
    local candidate
    local found=false
    mkdir -p "$dest"
    while IFS= read -r -d '' candidate; do
        cp -a "$candidate" "$dest/"
        found=true
    done < <(find "$CUSTOM_DEPENDENCY_LIBDIR" -maxdepth 1 -name "$pattern" \
        \( -type f -o -type l \) -print0 2>/dev/null)

    $found && echo "  OK $pattern (aus $CUSTOM_DEPENDENCY_LIBDIR)" \
           || { [ "$required" = "true" ] && fail "selbst gebaute Pflichtlib '$pattern' nicht gefunden!" \
                                          || echo "  WARNUNG selbst gebaute '$pattern' nicht gefunden"; }
}

# ── Hilfsfunktion: ELF-Abhängigkeiten rekursiv einbetten ────────────────────
# Kritisch für GStreamer: Plugins werden per Dateiname gefunden, aber wenn
# ihre Abhängigkeiten fehlen, ignoriert GStreamer sie stillschweigend.
copy_elf_deps_recursive() {
    local file="$1" dest_lib_dir="$2"
    [ -z "$file" ] || [ ! -e "$file" ] && return 0
    [ -z "$dest_lib_dir" ] && return 1
    mkdir -p "$dest_lib_dir"

    if [ -z "${__DINOX_DEPS_SEEN_INIT:-}" ]; then
        declare -gA __DINOX_DEPS_SEEN
        __DINOX_DEPS_SEEN_INIT=1
    fi

    local dep
    while IFS= read -r dep; do
        dep="${dep%)}" dep="${dep%(}"
        [ -e "$dep" ] || continue
        local base; base="$(basename "$dep")"
        if [ -n "${CUSTOM_LIBDIR:-}" ] && [ -e "$CUSTOM_LIBDIR/$base" ]; then
            __DINOX_DEPS_SEEN[$base]=1
            continue
        fi
        [ -n "${__DINOX_DEPS_SEEN[$base]:-}" ] && continue
        __DINOX_DEPS_SEEN[$base]=1
        if cp -L "$dep" "$dest_lib_dir/" 2>/dev/null; then
            record_distribution_source "$dest_lib_dir/$base" "$dep"
            copy_elf_deps_recursive "$dest_lib_dir/$base" "$dest_lib_dir"
        fi
    done < <(ldd "$file" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\//) print $i}')
}

require_build_needed() {
    local path="$1" soname="$2" label="$3"
    [ -s "$path" ] || fail "Build-Ausgabe für $label fehlt: $path"
    readelf -d "$path" 2>/dev/null | grep -F "Shared library: [$soname]" >/dev/null \
        || fail "$label wurde nicht gegen den erwarteten privaten SONAME $soname gebaut"
    echo "  OK $label verwendet $soname"
}

# ── Blacklist: System-Libs die NIE gebündelt werden dürfen ───────────────────
BLACKLIST=(
    "libc.so*" "libm.so*" "libdl.so*" "librt.so*" "libpthread.so*"
    "libresolv.so*" "libstdc++.so*" "libgcc_s.so*" "ld-linux*.so*"
    "libnss_*.so*" "libdrm.so*"
    "libxcb.so*" "libxcb-*.so*" "libX11.so*" "libX11-xcb.so*"
    "libXext.so*" "libXi.so*" "libXfixes.so*" "libXrender.so*"
    "libXcursor.so*" "libXdamage.so*" "libXrandr.so*" "libXcomposite.so*"
    # Cursor parsing is a portable helper, not a display-driver ABI. Ship it
    # for X11-only hosts where GTK's media backend still links against it.
    "libwayland-client.so*" "libwayland-server.so*" "libwayland-egl.so*"
    "libasound.so*" "libfontconfig.so*"
    "libfreetype.so*" "libharfbuzz.so*" "libcom_err.so*" "libexpat.so*"
    "libz.so*" "libpipewire-0.3.so*" "libfribidi.so*"
    "libgmp.so*" "libGL.so*" "libGLX.so*" "libGLdispatch.so*" "libEGL.so*"
    # libgstvaapi absichtlich nicht gebündelt — hardware-spezifisch,
    # verursacht Segfaults auf älteren Radeon GPUs
)

apply_blacklist() {
    local libdir="$1"
    for pattern in "${BLACKLIST[@]}"; do
        find "$libdir" -name "$pattern" -delete 2>/dev/null || true
    done
    echo "  OK Blacklist angewendet"
}

require_tor_version() {
    local bin="$1"
    local version
    version="$("$bin" --version 2>/dev/null | head -1 | sed -nE 's/^Tor version ([0-9]+(\.[0-9]+)*).*/\1/p')"
    if [ "$version" != "$TOR_REQUIRED_VERSION" ]; then
        fail "falsche Tor-Version in $bin: '${version:-unbekannt}', erwartet $TOR_REQUIRED_VERSION"
    fi
    echo "  OK Tor-Version $version"
}

require_lyrebird_version() {
    local bin="$1"
    local version
    version="$("$bin" --version 2>/dev/null | head -1 | sed -nE 's/^lyrebird ([^[:space:]]+).*/\1/p')"
    if [ "$version" != "$LYREBIRD_REQUIRED_VERSION" ]; then
        fail "falsche Lyrebird-Version in $bin: '${version:-unbekannt}', erwartet $LYREBIRD_REQUIRED_VERSION"
    fi
    echo "  OK Lyrebird-Version $version"
}

require_gnupg_version() {
    local bin="$1"
    local label="$2"
    local version
    version="$("$bin" --version 2>/dev/null | head -1 \
        | sed -nE 's/^.*\(GnuPG\) ([0-9]+(\.[0-9]+)+).*$/\1/p')"
    case "$version" in
        "$GNUPG_REQUIRED_SERIES".*) ;;
        *) fail "falsche GnuPG-Version für $label in $bin: '${version:-unbekannt}', erwartet $GNUPG_REQUIRED_SERIES.x" ;;
    esac
    echo "  OK $label GnuPG-Version $version"
}

copy_distribution_binary_with_deps() {
    local source="$1"
    local destination="$2"
    local label="$3"

    [ -x "$source" ] || fail "$label fehlt unter $source"
    dpkg-query -S "$source" >/dev/null 2>&1 \
        || fail "$source gehört zu keinem Debian/Ubuntu-Paket"
    install -D -m 0755 "$source" "$destination"
    record_distribution_source "$destination" "$source"
    copy_elf_deps_recursive "$destination" "$APPDIR/usr/lib"
    echo "  OK $label mit rekursiver ELF-Runtime"
}

find_runtime_binary() {
    local name="$1"
    if [ -x "$CUSTOM_DEPENDENCY_BINDIR/$name" ]; then
        printf '%s\n' "$CUSTOM_DEPENDENCY_BINDIR/$name"
    fi
    return 0
}

# ── Schritt 0: Prerequisites prüfen ──────────────────────────────────────────
step "Schritt 0: Prerequisites prüfen"
for tool in meson ninja patchelf wget sha256sum readelf dpkg-query dpkg-source pkg-config gio-querymodules \
        apt-get apt-cache tar \
        gpg gpgconf gpg-agent dirmngr gpg-connect-agent curl; do
    command -v "$tool" &>/dev/null \
        && echo "  OK $tool" \
        || fail "$tool nicht gefunden — sudo apt install $tool"
done
[ -d "$CUSTOM_DEPENDENCY_LIBDIR/pkgconfig" ] \
    || fail "isolierte CI-Abhängigkeiten fehlen unter $CUSTOM_DEPENDENCY_PREFIX; zuerst scripts/ci-build-deps.sh ausführen"
bash "$PROJECT_ROOT/scripts/verify-ci-deps.sh"
bash "$PROJECT_ROOT/scripts/prepare-ibus-compat.sh" --prefix "$IBUS_COMPAT_PREFIX"
bash "$PROJECT_ROOT/scripts/prepare-canberra-runtime.sh" --prefix "$CANBERRA_RUNTIME_PREFIX"

# ── Schritt 1: appimagetool herunterladen ────────────────────────────────────
step "Schritt 1: appimagetool bereitstellen"
mkdir -p "$TOOLS_DIR"
LICENSE_SOURCE_MAP="$(mktemp "$TOOLS_DIR/appimage-license-sources.XXXXXX")"
PROJECT_INSTALL_MAP="$(mktemp "$TOOLS_DIR/appimage-project-install.XXXXXX")"

APPIMAGETOOL="$TOOLS_DIR/appimagetool-${TOOL_ARCH}.AppImage"
APPIMAGETOOL_URL="https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/appimagetool-${TOOL_ARCH}.AppImage"
APPIMAGETOOL_RUNTIME="$TOOLS_DIR/runtime-${TOOL_ARCH}"
APPIMAGETOOL_RUNTIME_URL="https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/runtime-${TOOL_ARCH}"
APPIMAGETOOL_RUNTIME_SHA="${APPIMAGETOOL_RUNTIME}.sha256"
APPIMAGETOOL_RUNTIME_SHA_URL="${APPIMAGETOOL_RUNTIME_URL}.sha256"

APPIMAGETOOL_EXPECTED_SHA256="a6d71e2b6cd66f8e8d16c37ad164658985e0cf5fcaa950c90a482890cb9d13e0"
APPIMAGE_VENDOR_RUNTIME_EXPECTED_SHA256="a2419dce47568395ae79c01ffa9a5a341dd339581352ff104d073527543177e5"

if [ -f "$APPIMAGETOOL" ] \
        && ! sha256_matches "$APPIMAGETOOL" "$APPIMAGETOOL_EXPECTED_SHA256"; then
    echo "  Verwerfe appimagetool mit abweichender Prüfsumme"
    rm -f "$APPIMAGETOOL"
fi
if [ ! -f "$APPIMAGETOOL" ]; then
    echo "  Lade appimagetool herunter..."
    if ! wget -q --show-progress -O "${APPIMAGETOOL}.tmp" "$APPIMAGETOOL_URL"; then
        fail "appimagetool fuer ${TOOL_ARCH} nicht im Forgejo vendor-deps Release gefunden: ${APPIMAGETOOL_URL}"
    fi
    verify_sha256 "${APPIMAGETOOL}.tmp" "$APPIMAGETOOL_EXPECTED_SHA256" "appimagetool-${TOOL_ARCH}"
    mv "${APPIMAGETOOL}.tmp" "$APPIMAGETOOL"
    chmod +x "$APPIMAGETOOL"
fi
verify_sha256 "$APPIMAGETOOL" "$APPIMAGETOOL_EXPECTED_SHA256" "appimagetool-${TOOL_ARCH}"
echo "  OK appimagetool bereit"

verify_appimage_runtime() {
    local runtime="$1"
    local expected="$2"
    verify_sha256 "$runtime" "$expected" "$(basename "$runtime")"
}

APPIMAGETOOL_RUNTIME_ARGS=()
if [ -n "${APPIMAGE_RUNTIME_FILE:-}" ]; then
    if [ ! -f "$APPIMAGE_RUNTIME_FILE" ]; then
        fail "APPIMAGE_RUNTIME_FILE existiert nicht: $APPIMAGE_RUNTIME_FILE"
    fi
    if [ -n "${APPIMAGE_RUNTIME_SHA256:-}" ]; then
        APPIMAGE_RUNTIME_EXPECTED_SHA256="$APPIMAGE_RUNTIME_SHA256"
    elif [ -s "${APPIMAGE_RUNTIME_FILE}.sha256" ]; then
        APPIMAGE_RUNTIME_EXPECTED_SHA256="$(sha256_from_file "${APPIMAGE_RUNTIME_FILE}.sha256")"
    else
        fail "für APPIMAGE_RUNTIME_FILE fehlt APPIMAGE_RUNTIME_SHA256 oder ${APPIMAGE_RUNTIME_FILE}.sha256"
    fi
    verify_appimage_runtime "$APPIMAGE_RUNTIME_FILE" "$APPIMAGE_RUNTIME_EXPECTED_SHA256"
    APPIMAGETOOL_RUNTIME_ARGS=(--runtime-file "$APPIMAGE_RUNTIME_FILE")
    echo "  OK AppImage Runtime aus APPIMAGE_RUNTIME_FILE"
else
    if [ ! -f "$APPIMAGETOOL_RUNTIME" ] || [ ! -s "$APPIMAGETOOL_RUNTIME_SHA" ]; then
        echo "  Lade AppImage Runtime aus Forgejo vendor-deps..."
        if ! wget -q --show-progress -O "${APPIMAGETOOL_RUNTIME}.tmp" "$APPIMAGETOOL_RUNTIME_URL" \
            || ! wget -q --show-progress -O "${APPIMAGETOOL_RUNTIME_SHA}.tmp" "$APPIMAGETOOL_RUNTIME_SHA_URL"; then
            rm -f "${APPIMAGETOOL_RUNTIME}.tmp"
            rm -f "${APPIMAGETOOL_RUNTIME_SHA}.tmp"
            fail "runtime-${TOOL_ARCH} oder seine SHA256-Datei fehlt im Forgejo vendor-deps Release"
        fi
        APPIMAGE_RUNTIME_EXPECTED_SHA256="$(sha256_from_file "${APPIMAGETOOL_RUNTIME_SHA}.tmp")"
        [ "$APPIMAGE_RUNTIME_EXPECTED_SHA256" = "$APPIMAGE_VENDOR_RUNTIME_EXPECTED_SHA256" ] \
            || fail "veröffentlichte Prüfsumme für runtime-${TOOL_ARCH} weicht vom Repository-Pin ab"
        verify_appimage_runtime "${APPIMAGETOOL_RUNTIME}.tmp" "$APPIMAGE_RUNTIME_EXPECTED_SHA256"
        mv "${APPIMAGETOOL_RUNTIME}.tmp" "$APPIMAGETOOL_RUNTIME"
        mv "${APPIMAGETOOL_RUNTIME_SHA}.tmp" "$APPIMAGETOOL_RUNTIME_SHA"
    fi
    APPIMAGE_RUNTIME_EXPECTED_SHA256="$(sha256_from_file "$APPIMAGETOOL_RUNTIME_SHA")"
    [ "$APPIMAGE_RUNTIME_EXPECTED_SHA256" = "$APPIMAGE_VENDOR_RUNTIME_EXPECTED_SHA256" ] \
        || fail "gecachte Prüfsumme für runtime-${TOOL_ARCH} weicht vom Repository-Pin ab"
    verify_appimage_runtime "$APPIMAGETOOL_RUNTIME" "$APPIMAGE_RUNTIME_EXPECTED_SHA256"
    APPIMAGETOOL_RUNTIME_ARGS=(--runtime-file "$APPIMAGETOOL_RUNTIME")
    echo "  OK AppImage Runtime aus .appimage-tools Cache"
fi

# ── Schritt 2: Meson konfigurieren & bauen ───────────────────────────────────
step "Schritt 2: Meson konfigurieren & kompilieren"

MESON_COMMON=()
# Ein AppImage-Build darf niemals Meson-Zustand aus einem Entwickler- oder
# früheren Paketbuild übernehmen.
rm -rf "$BUILD_DIR"
MESON_COMMON=(
    --prefix=/usr
    --buildtype=debugoptimized
    -Dplugin-mqtt=enabled
    -Ddnssec=enabled
    -Dplugin-rtp=disabled
    -Dplugin-google-webrtc=enabled
    -Dgoogle-libwebrtc-wrapper=enabled
    -Dgoogle-libwebrtc-test-oracle=false
    -Dgoogle-libwebrtc-tests=false
    "-Dgoogle-libwebrtc-runtime-root=$DINOX_LIBWEBRTC_RUNTIME_ROOT"
    -Dlocation-sharing=enabled
    -Dplugin-http-files=enabled
    -Dplugin-ice=enabled
    -Dplugin-omemo=enabled
    -Dplugin-openpgp=enabled
    -Dplugin-notification-sound=enabled
)
meson setup "$BUILD_DIR" "$PROJECT_ROOT" "${MESON_COMMON[@]}" $MESON_ARGS

if [ "${#NINJA_ARGS[@]}" -gt 0 ]; then
    echo "  Build-Jobs: ${NINJA_ARGS[1]}"
fi
ninja -C "$BUILD_DIR" "${NINJA_ARGS[@]}"
require_build_needed "$BUILD_DIR/qlite/libqlite.so.0.1" libsqlcipher.so.0 "QLite/SQLCipher"
require_build_needed "$BUILD_DIR/plugins/ice/ice.so" libnice.so.10 "Jingle ICE/libnice"
require_build_needed "$BUILD_DIR/plugins/omemo/omemo.so" libomemo-c.so.0 "OMEMO/libomemo-c"
require_build_needed "$BUILD_DIR/plugins/mqtt/mqtt.so" libmosquitto.so.1 "MQTT/libmosquitto"
require_build_needed "$BUILD_DIR/xmpp-vala/libxmpp-vala.so.0.1" libunbound.so.8 "DNSSEC/libunbound"
echo "  OK Build abgeschlossen"

# ── Schritt 3: AppDir aufbauen ───────────────────────────────────────────────
step "Schritt 3: AppDir via Meson install aufbauen"

rm -rf "$APPDIR"
mkdir -p "$APPDIR"
DESTDIR="$APPDIR" meson install --no-rebuild -C "$BUILD_DIR"

# /usr/local nach /usr verschieben falls nötig
if [ -d "$APPDIR/usr/local" ]; then
    cp -a "$APPDIR/usr/local/." "$APPDIR/usr/"
    rm -rf "$APPDIR/usr/local"
fi

# Multiarch-Libs konsolidieren
LIB_DIR="$APPDIR/usr/lib"
if [ -d "$LIB_DIR/$TRIPLET" ]; then
    cp -Lr "$LIB_DIR/$TRIPLET/"*.so* "$LIB_DIR/" 2>/dev/null || true
    if [ -d "$LIB_DIR/$TRIPLET/dino" ]; then
        mkdir -p "$LIB_DIR/dino"
        cp -r "$LIB_DIR/$TRIPLET/dino/." "$LIB_DIR/dino/"
    fi
fi

# Freeze the exact Meson-owned install surface before any custom or
# distribution runtime file is copied into AppDir. The license stager uses this
# allowlist only for AppDir-internal dependency edges; external files must still
# resolve to an installed Debian package and exact source package.
snapshot_project_install_paths "$PROJECT_INSTALL_MAP"

echo "  OK AppDir Grundstruktur erstellt"

# Vision is a separately spawned inference process, so DT_NEEDED traversal of
# the call plugin cannot discover it. Preserve the producer's bytes and hashes.
python3 "$SCRIPT_DIR/check-vision-runtime.py" --base "$APPDIR/usr/lib/dinox" --platform linux

# ── Schritt 4: Custom-Bibliotheken ───────────────────────────────────────────
step "Schritt 4: Custom-Bibliotheken einbetten"

mkdir -p "$APPDIR/usr/lib/dinox"
CUSTOM_LIBDIR="$APPDIR/usr/lib/dinox"
echo "  Private Build-Abhängigkeiten: $CUSTOM_DEPENDENCY_PREFIX"

# Install this before collecting ELF dependencies so the distro's libcanberra
# cannot reintroduce its compiled-in host module path.
CANBERRA_RUNTIME="$CANBERRA_RUNTIME_PREFIX/lib/dinox/canberra-runtime"
install -m 0644 "$CANBERRA_RUNTIME/libcanberra.so.0" "$CUSTOM_LIBDIR/libcanberra.so.0"
mkdir -p "$CUSTOM_LIBDIR/canberra"
install -m 0644 "$CANBERRA_RUNTIME/modules/"*.so "$CUSTOM_LIBDIR/canberra/"
install -m 0644 "$CANBERRA_RUNTIME/METADATA" "$CUSTOM_LIBDIR/canberra/METADATA"
for canberra_library in "$CUSTOM_LIBDIR/libcanberra.so.0" "$CUSTOM_LIBDIR/canberra/"*.so; do
    copy_elf_deps_recursive "$canberra_library" "$APPDIR/usr/lib"
done

# Sound event names used by notification-sound need a portable fallback theme.
# Desktop-specific user themes can still take precedence through libcanberra.
SOUND_SOURCE_DIR=/usr/share/sounds/freedesktop
[ -s "$SOUND_SOURCE_DIR/index.theme" ] || fail "sound-theme-freedesktop fehlt"
while IFS= read -r -d '' sound; do
    target="$APPDIR/usr/share/sounds/freedesktop/${sound#"$SOUND_SOURCE_DIR/"}"
    install -D -m 0644 "$sound" "$target"
    record_distribution_source "$target" "$sound"
done < <(find "$SOUND_SOURCE_DIR" \( -type f -o -type l \) -print0)

install -D -m 0644 \
    "$IBUS_COMPAT_PREFIX/lib/dinox/ibus-compat/libibus-1.0.so.5.0.530" \
    "$CUSTOM_LIBDIR/ibus-compat/libibus-1.0.so.5.0.530"
install -m 0644 "$IBUS_COMPAT_PREFIX/lib/dinox/ibus-compat/METADATA" \
    "$CUSTOM_LIBDIR/ibus-compat/METADATA"
copy_elf_deps_recursive "$CUSTOM_LIBDIR/ibus-compat/libibus-1.0.so.5.0.530" "$APPDIR/usr/lib"

copy_custom_lib "libsqlcipher.so*"         "$CUSTOM_LIBDIR" true
copy_lib "libgeoclue-2.so*"                "$CUSTOM_LIBDIR" true
copy_custom_lib "libomemo-c.so*"           "$CUSTOM_LIBDIR" true
copy_custom_lib "libnice.so*"              "$CUSTOM_LIBDIR" true
copy_custom_lib "libmosquitto.so*"         "$CUSTOM_LIBDIR" true
copy_lib "libunbound.so*"                   "$CUSTOM_LIBDIR" true
copy_custom_lib "libcjson.so*"             "$CUSTOM_LIBDIR" true
copy_lib "libevent-*.so*"                  "$CUSTOM_LIBDIR" true
copy_lib "libevent_core*.so*"              "$CUSTOM_LIBDIR" false
copy_lib "libevent_pthreads*.so*"          "$CUSTOM_LIBDIR" false
copy_lib "libevent_extra*.so*"             "$CUSTOM_LIBDIR" false
copy_lib "libevent_openssl*.so*"           "$CUSTOM_LIBDIR" false
copy_custom_lib "libprotobuf-c.so*"        "$CUSTOM_LIBDIR" true
copy_lib "libsrtp2.so*"                    "$CUSTOM_LIBDIR" false
copy_lib "libva.so*"                       "$CUSTOM_LIBDIR" true
copy_lib "libva-drm.so*"                   "$CUSTOM_LIBDIR" true

# Ubuntu's libsrtp2 is built against NSS/NSPR. The Google/libwebrtc runtime
# loads this private copy, so its non-system dependency closure must travel
# with the AppImage as well.
SRTP_RUNTIME_LIB="$CUSTOM_LIBDIR/libsrtp2.so.1"
[ -f "$SRTP_RUNTIME_LIB" ] \
    || fail "libsrtp2 Runtime fehlt nach dem Einbetten"
copy_elf_deps_recursive "$SRTP_RUNTIME_LIB" "$APPDIR/usr/lib"
# NSS opens its software token/crypto modules dynamically during SRTP setup;
# ldd alone does not find them. Place them beside the bundled libnss3.
for nss_module in libsoftokn3.so libfreebl3.so libfreeblpriv3.so libnssckbi.so; do
    module="/usr/lib/$TRIPLET/$nss_module"
    [ -s "$module" ] || fail "NSS-Laufzeitmodul fehlt: $module"
    install -m 0644 "$module" "$APPDIR/usr/lib/$nss_module"
    record_distribution_source "$APPDIR/usr/lib/$nss_module" "$module"
    copy_elf_deps_recursive "$APPDIR/usr/lib/$nss_module" "$APPDIR/usr/lib"
done
copy_elf_deps_recursive "$CUSTOM_LIBDIR/dinox-vision-worker" "$APPDIR/usr/lib"

# ELF-Abhängigkeiten der DinoX-Plugins rekursiv einbetten
for plugin in \
    "$APPDIR/usr/lib/$TRIPLET/dino/plugins/"*.so \
    "$APPDIR/usr/lib/dino/plugins/"*.so; do
    [ -f "$plugin" ] && copy_elf_deps_recursive "$plugin" "$APPDIR/usr/lib"
done

# ── Schritt 4a: private ffmpeg for audio/video messages ──
# Linux media-message recording writes M4A/MP4 through this purpose-built CLI.
# Its FFmpeg/x264 codec libraries are statically linked, so it cannot resolve
# against the private dynamic libavcodec/libavutil used by Google/libwebrtc.
step "Schritt 4a: privaten Recorder-ffmpeg einbetten"

mkdir -p "$APPDIR/usr/bin"
[ -x "$RECORDER_FFMPEG_SOURCE" ] \
    || fail "privater Recorder-ffmpeg fehlt: $RECORDER_FFMPEG_SOURCE"
RECORDER_FFMPEG_REAL="$(realpath -e "$RECORDER_FFMPEG_SOURCE")"
case "$RECORDER_FFMPEG_REAL" in
    "$CUSTOM_DEPENDENCY_PREFIX"/*) ;;
    *) fail "Recorder-ffmpeg liegt außerhalb des privaten Dependency-Prefixes: $RECORDER_FFMPEG_REAL" ;;
esac
if LC_ALL=C readelf -d --wide "$RECORDER_FFMPEG_REAL" 2>/dev/null \
        | grep -Eq 'Shared library: \[lib(avcodec|avdevice|avfilter|avformat|avutil|postproc|swresample|swscale|x264)\.so'; then
    fail "privater Recorder-ffmpeg bindet eine dynamische Codec-Bibliothek ein"
fi
cp -L "$RECORDER_FFMPEG_REAL" "$APPDIR/usr/bin/ffmpeg"
chmod 755 "$APPDIR/usr/bin/ffmpeg"
echo "  OK privater statischer FFmpeg/x264-Recorder ohne Codec-SONAME-Kollision"

# ── Schritt 4b: GnuPG for the OpenPGP plugin ────────────────────────────────
# DinoX invokes gpg and gpgconf directly. GnuPG then needs its own agent and
# dirmngr; gpgconf uses gpg-connect-agent for the bounded shutdown performed by
# the plugin. Pinentry is deliberately absent because every private-key action
# uses DinoX-managed batch/loopback passphrases, and scdaemon is disabled in the
# app-scoped gpg-agent.conf.
step "Schritt 4b: private GnuPG-Runtime für OpenPGP einbetten"

GNUPG_RUNTIME_BINARIES=(gpg gpgconf gpg-agent dirmngr gpg-connect-agent)
for binary in "${GNUPG_RUNTIME_BINARIES[@]}"; do
    source_binary="/usr/bin/$binary"
    require_gnupg_version "$source_binary" "$binary"
    copy_distribution_binary_with_deps \
        "$source_binary" "$APPDIR/usr/bin/$binary" "$binary"
done

# The OpenPGP helper uses curl for the keys.openpgp.org VKS API fallback.
copy_distribution_binary_with_deps \
    /usr/bin/curl "$APPDIR/usr/bin/curl" "curl für OpenPGP-Keyserver"

# GnuPG 2.4 supports a relocatable Unix installation through gpgconf.ctl. The
# literal APPDIR reference is expanded by GnuPG at runtime, keeping helper
# discovery and global configuration inside the mounted AppImage.
mkdir -p "$APPDIR/usr/etc/gnupg" "$APPDIR/usr/share/gnupg"
cat > "$APPDIR/usr/bin/gpgconf.ctl" <<'GNUPGCONF_CTL'
rootdir = ${APPDIR}/usr
sysconfdir = ${APPDIR}/usr/etc/gnupg
GNUPGCONF_CTL
chmod 0644 "$APPDIR/usr/bin/gpgconf.ctl"

GNUPG_KEYSERVER_CA=/usr/share/gnupg/sks-keyservers.netCA.pem
[ -s "$GNUPG_KEYSERVER_CA" ] \
    || fail "GnuPG-Keyserver-CA fehlt: $GNUPG_KEYSERVER_CA"
install -m 0644 "$GNUPG_KEYSERVER_CA" \
    "$APPDIR/usr/share/gnupg/sks-keyservers.netCA.pem"
record_distribution_source \
    "$APPDIR/usr/share/gnupg/sks-keyservers.netCA.pem" "$GNUPG_KEYSERVER_CA"
echo "  OK relocatable GnuPG-Konfiguration und Keyserver-Daten"

# GIO and GTK discover modules at runtime, outside the ELF DT_NEEDED graph.
# Ship modules from the same build environment as GLib/GTK: host modules may
# require newer symbols (for example Debian 13 with our Ubuntu 24.04 runtime).
step "Schritt 4c: GIO- und GTK-Module einbetten"
GIO_SOURCE_DIR="$(pkg-config --variable=giomoduledir gio-2.0)"
GIO_TARGET_DIR="$APPDIR/usr/lib/gio/modules"
[ -n "$GIO_SOURCE_DIR" ] && [ -s "$GIO_SOURCE_DIR/libgiognutls.so" ] \
    || fail "GIO-TLS-Modul libgiognutls.so fehlt; glib-networking installieren"
for required_module in libdconfsettings.so libgiolibproxy.so libgiognomeproxy.so libgvfsdbus.so; do
    [ -s "$GIO_SOURCE_DIR/$required_module" ] \
        || fail "GIO-Desktop-Modul $required_module fehlt; glib-networking, dconf-gsettings-backend und gvfs installieren"
done
for module in "$GIO_SOURCE_DIR"/*.so; do
    [ -f "$module" ] || continue
    target="$GIO_TARGET_DIR/$(basename "$module")"
    install -D -m 0644 "$module" "$target"
    record_distribution_source "$target" "$module"
    copy_elf_deps_recursive "$target" "$APPDIR/usr/lib"
done
gio-querymodules "$GIO_TARGET_DIR"
[ -s "$GIO_TARGET_DIR/giomodule.cache" ] \
    || fail "GIO-Modulcache konnte nicht erstellt werden"

GTK_MODULE_VERSION="$(pkg-config --variable=gtk_binary_version gtk4)"
GTK_SOURCE_DIR="$(pkg-config --variable=libdir gtk4)/gtk-4.0/$GTK_MODULE_VERSION"
GTK_TARGET_DIR="$APPDIR/usr/lib/gtk-4.0/$GTK_MODULE_VERSION"
[ -n "$GTK_MODULE_VERSION" ] && [ -s "$GTK_SOURCE_DIR/media/libmedia-gstreamer.so" ] \
    || fail "GTK-Medienmodul libmedia-gstreamer.so fehlt; libgtk-4-media-gstreamer installieren"
while IFS= read -r -d '' module; do
    target="$GTK_TARGET_DIR/${module#"$GTK_SOURCE_DIR/"}"
    install -D -m 0644 "$module" "$target"
    record_distribution_source "$target" "$module"
    copy_elf_deps_recursive "$target" "$APPDIR/usr/lib"
done < <(find "$GTK_SOURCE_DIR" \( -type f -o -type l \) -name '*.so' -print0)

# OpenSSL providers and engines are also loaded by filename. Keep their ABI
# aligned with the bundled libcrypto, including for helpers such as curl.
for module_family in ossl-modules engines-3; do
    module_source="/usr/lib/$TRIPLET/$module_family"
    [ -d "$module_source" ] || fail "OpenSSL-Modulverzeichnis fehlt: $module_source"
    for module in "$module_source"/*.so; do
        [ -f "$module" ] || continue
        target="$APPDIR/usr/lib/$module_family/$(basename "$module")"
        install -D -m 0644 "$module" "$target"
        record_distribution_source "$target" "$module"
        copy_elf_deps_recursive "$target" "$APPDIR/usr/lib"
    done
done

# GStreamer remains the playback, demux, decode and metadata layer.
step "Schritt 5: GStreamer-Plugins einbetten"

GST_LIBDIR="$APPDIR/usr/lib/gstreamer-1.0"
mkdir -p "$GST_LIBDIR"

GST_PLUGIN_DIR=$(pkg-config --variable=pluginsdir gstreamer-1.0 2>/dev/null \
    || echo "/usr/lib/$TRIPLET/gstreamer-1.0")
GST_SCANNER_DIR=$(pkg-config --variable=pluginscannerdir gstreamer-1.0 2>/dev/null \
    || echo "/usr/lib/$TRIPLET/gstreamer1.0/gstreamer-1.0")

# gst-plugin-scanner — ohne Scanner ignoriert GStreamer gebündelte Plugins
if [ -x "$GST_SCANNER_DIR/gst-plugin-scanner" ]; then
    cp -L "$GST_SCANNER_DIR/gst-plugin-scanner" "$GST_LIBDIR/"
    record_distribution_source "$GST_LIBDIR/gst-plugin-scanner" "$GST_SCANNER_DIR/gst-plugin-scanner"
    copy_elf_deps_recursive "$GST_LIBDIR/gst-plugin-scanner" "$APPDIR/usr/lib"
    echo "  OK gst-plugin-scanner"
else
    fail "gst-plugin-scanner nicht gefunden in $GST_SCANNER_DIR"
fi

gst_copy() {
    local name="$1"
    if [ -f "$GST_PLUGIN_DIR/$name" ]; then
        cp "$GST_PLUGIN_DIR/$name" "$GST_LIBDIR/"
        record_distribution_source "$GST_LIBDIR/$name" "$GST_PLUGIN_DIR/$name"
        copy_elf_deps_recursive "$GST_LIBDIR/$name" "$APPDIR/usr/lib"
        echo "  OK $name"
    else
        fail "$name nicht in $GST_PLUGIN_DIR"
    fi
}

# GStreamer only demuxes/decodes media, extracts metadata/thumbnails and feeds
# decoded PCM through appsink into the Google/libwebrtc output device. The
# audio-sink plugins are retained solely for the MQTT alert playbin. Capture,
# recording, RTP, WebRTC and NICE GStreamer plugins are deliberately absent.
GST_PLAYBACK_PLUGINS=(
    libgstcoreelements.so
    libgstapp.so
    libgsttypefindfunctions.so
    libgstplayback.so
    libgstgio.so
    libgstaudioparsers.so
    libgstaudioconvert.so
    libgstaudioresample.so
    libgstlevel.so
    libgstvolume.so
    libgstopus.so
    libgstvorbis.so
    libgstvpx.so
    libgstlibav.so
    libgstvideoconvertscale.so
    libgstvideoparsersbad.so
    libgstisomp4.so
    libgstmatroska.so
    libgstogg.so
    libgstwavparse.so
    libgstautodetect.so
    libgstpulseaudio.so
    libgstalsa.so
    libgstpipewire.so
)
for gst_plugin in "${GST_PLAYBACK_PLUGINS[@]}"; do
    gst_copy "$gst_plugin"
done

# ── Schritt 5a: GdkPixbuf-Loader für moderne Bildformate ────────────────────
step "Schritt 5a: GdkPixbuf-Loader einbetten"

PIXBUF_SRC="/usr/lib/$TRIPLET/gdk-pixbuf-2.0/2.10.0"
PIXBUF_DEST="$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0"
if [ -d "$PIXBUF_SRC/loaders" ]; then
    mkdir -p "$PIXBUF_DEST/loaders"
    cp -a "$PIXBUF_SRC/loaders/." "$PIXBUF_DEST/loaders/"
    while IFS= read -r -d '' source_loader; do
        record_distribution_source \
            "$PIXBUF_DEST/loaders/$(basename "$source_loader")" "$source_loader"
    done < <(find "$PIXBUF_SRC/loaders" -maxdepth 1 \( -type f -o -type l \) -print0)
    for loader in "$PIXBUF_DEST/loaders/"*.so; do
        [ -f "$loader" ] && copy_elf_deps_recursive "$loader" "$APPDIR/usr/lib"
    done

    PIXBUF_QUERY="/usr/lib/$TRIPLET/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders"
    if [ -x "$PIXBUF_QUERY" ]; then
        cp "$PIXBUF_QUERY" "$APPDIR/usr/bin/gdk-pixbuf-query-loaders"
        record_distribution_source "$APPDIR/usr/bin/gdk-pixbuf-query-loaders" "$PIXBUF_QUERY"
        copy_elf_deps_recursive "$APPDIR/usr/bin/gdk-pixbuf-query-loaders" "$APPDIR/usr/lib"
        GDK_PIXBUF_MODULEDIR="$PIXBUF_DEST/loaders" "$PIXBUF_QUERY" > "$PIXBUF_DEST/loaders.cache"
        sed -i "s|$APPDIR||g" "$PIXBUF_DEST/loaders.cache"
        ok "GdkPixbuf-Loader und Cache kopiert"
    else
        fail "gdk-pixbuf-query-loaders nicht gefunden"
    fi
else
    warn "GdkPixbuf-Loader nicht gefunden in $PIXBUF_SRC"
fi

# The HEIF pixbuf loader also discovers codec plugins dynamically. Shipping
# libheif alone would still load codecs from the host distribution.
HEIF_SOURCE_DIR="/usr/lib/$TRIPLET/libheif/plugins"
HEIF_TARGET_DIR="$APPDIR/usr/lib/libheif/plugins"
[ -s "$HEIF_SOURCE_DIR/libheif-dav1d.so" ] \
    || fail "HEIF-AV1-Decoder fehlt; libheif-plugin-dav1d installieren"
[ -s "$HEIF_SOURCE_DIR/libheif-libde265.so" ] \
    || fail "HEIF-HEVC-Decoder fehlt; libheif-plugin-libde265 installieren"
for module in "$HEIF_SOURCE_DIR"/*.so; do
    [ -f "$module" ] || continue
    target="$HEIF_TARGET_DIR/$(basename "$module")"
    install -D -m 0644 "$module" "$target"
    record_distribution_source "$target" "$module"
    copy_elf_deps_recursive "$target" "$APPDIR/usr/lib"
done

# ── Schritt 6: Tor und Lyrebird ──────────────────────────────────────────────
step "Schritt 6: Tor und Lyrebird einbetten"

mkdir -p "$APPDIR/usr/bin"
for binary in tor lyrebird; do
    BIN_PATH="$(find_runtime_binary "$binary")"
    if [ -n "$BIN_PATH" ]; then
        cp "$BIN_PATH" "$APPDIR/usr/bin/$binary"
        chmod 755 "$APPDIR/usr/bin/$binary"
        record_distribution_source "$APPDIR/usr/bin/$binary" "$BIN_PATH"
        echo "  OK $binary ($BIN_PATH)"
    else
        echo "  WARNUNG $binary nicht gefunden"
    fi
done
require_tor_version "$APPDIR/usr/bin/tor"
require_lyrebird_version "$APPDIR/usr/bin/lyrebird"
copy_elf_deps_recursive "$APPDIR/usr/bin/tor" "$CUSTOM_LIBDIR"
copy_elf_deps_recursive "$APPDIR/usr/bin/lyrebird" "$CUSTOM_LIBDIR"
TOR_DATA_SOURCE="$CUSTOM_DEPENDENCY_PREFIX/share/tor"
TOR_DATA_DEST="$APPDIR/usr/share/dinox/tor"
for tor_data_file in geoip geoip6; do
    [ -s "$TOR_DATA_SOURCE/$tor_data_file" ] \
        || fail "private Tor-Datendatei fehlt: $TOR_DATA_SOURCE/$tor_data_file"
    install -D -m 0644 "$TOR_DATA_SOURCE/$tor_data_file" "$TOR_DATA_DEST/$tor_data_file"
done

# ── Schritt 7: Icons ─────────────────────────────────────────────────────────
step "Schritt 7: Icons kopieren"

for size in 16x16 32x32 48x48 128x128 256x256 512x512; do
    SRC="$PROJECT_ROOT/main/data/icons/hicolor/$size/apps/im.dinox.dinox.png"
    if [ -f "$SRC" ]; then
        DEST_DIR="$APPDIR/usr/share/icons/hicolor/$size/apps"
        mkdir -p "$DEST_DIR"
        cp "$SRC" "$DEST_DIR/im.dinox.dinox.png"
        echo "  OK Icon $size"
    fi
done

# 256x256 in AppDir-Root für AppImage-Thumbnail + .DirIcon
ROOT_ICON="$PROJECT_ROOT/main/data/icons/hicolor/256x256/apps/im.dinox.dinox.png"
if [ -f "$ROOT_ICON" ]; then
    cp "$ROOT_ICON" "$APPDIR/im.dinox.dinox.png"
    ln -sf "im.dinox.dinox.png" "$APPDIR/.DirIcon"
    echo "  OK .DirIcon gesetzt"
fi

gtk4-update-icon-cache -f -t "$APPDIR/usr/share/icons/hicolor" 2>/dev/null \
    || gtk-update-icon-cache  -f -t "$APPDIR/usr/share/icons/hicolor" 2>/dev/null \
    || true

# ── Schritt 8: Desktop-Datei ─────────────────────────────────────────────────
step "Schritt 8: Desktop-Datei"

DESKTOP_FILE="$PROJECT_ROOT/main/data/im.dinox.dinox.desktop"
[ -f "$DESKTOP_FILE" ] || fail "Desktop-Datei fehlt: $DESKTOP_FILE"
cp "$DESKTOP_FILE" "$APPDIR/im.dinox.dinox.desktop"
cp "$APPDIR/im.dinox.dinox.desktop" "$APPDIR/usr/share/applications/"
echo "  OK Desktop-Datei erstellt"

# ── Schritt 9: GLib Schemas kompilieren ──────────────────────────────────────
step "Schritt 9: GLib Schemas kompilieren"

SCHEMA_DIR="$APPDIR/usr/share/glib-2.0/schemas"
mkdir -p "$SCHEMA_DIR"
# GIO's GNOME proxy resolver aborts when its schema is absent. GTK's own
# settings must also work on desktops which do not install GNOME/GTK schemas.
for schema in \
    /usr/share/glib-2.0/schemas/org.gnome.system.proxy.gschema.xml \
    /usr/share/glib-2.0/schemas/org.gnome.desktop.enums.xml \
    /usr/share/glib-2.0/schemas/org.gtk.gtk4.Settings.*.gschema.xml; do
    [ -s "$schema" ] || fail "GLib-Laufzeitschema fehlt: $schema"
    target="$SCHEMA_DIR/$(basename "$schema")"
    install -m 0644 "$schema" "$target"
    record_distribution_source "$target" "$schema"
done
glib-compile-schemas --strict "$SCHEMA_DIR"
echo "  OK Schemas kompiliert"

# ── Schritt 9a: RPATH patchen ────────────────────────────────────────────────
step "Schritt 9a: RPATH mit patchelf patchen"

# dinox Binary — kein RPATH, findet libdino.so.0 nicht im AppImage
patchelf --set-rpath "\$ORIGIN/../lib/$TRIPLET:\$ORIGIN/../lib" "$APPDIR/usr/bin/dinox" 2>/dev/null && echo "  OK dinox Binary gepatcht" || true

# DinoX-eigene Libs patchen
for lib in \
    "$APPDIR/usr/lib/$TRIPLET/libdino.so.0" \
    "$APPDIR/usr/lib/$TRIPLET/libcrypto-vala.so.0" \
    "$APPDIR/usr/lib/$TRIPLET/libxmpp-vala.so.0" \
    "$APPDIR/usr/lib/$TRIPLET/libqlite.so.0"; do
    [ -f "$lib" ] && patchelf --set-rpath "\$ORIGIN:\$ORIGIN/../$TRIPLET:\$ORIGIN/.." "$lib" && echo "  OK $(basename $lib) gepatcht" || true
done

# Ubuntu baut libpulse mit einem absoluten RUNPATH auf sein distributions-
# internes pulseaudio-Unterverzeichnis. Im AppDir liegt libpulsecommon nach der
# Abhaengigkeitskonsolidierung direkt daneben; halte diese Aufloesung deshalb
# paketrelativ und auf anderen Distributionen funktionsfaehig.
PULSE_CLIENT_LIB="$APPDIR/usr/lib/libpulse.so.0"
if [ -f "$PULSE_CLIENT_LIB" ]; then
    patchelf --set-rpath "\$ORIGIN" "$PULSE_CLIENT_LIB" \
        || fail "libpulse RUNPATH konnte nicht paketrelativ gesetzt werden"
    echo "  OK libpulse RUNPATH gepatcht"
fi

# GVfs and libproxy also carry distro-specific RUNPATH entries. Their support
# libraries have been consolidated into usr/lib, so relocate those edges too.
for module in "$APPDIR/usr/lib/gio/modules/"*.so; do
    [ -f "$module" ] || continue
    patchelf --set-rpath '$ORIGIN:$ORIGIN/../..' "$module" \
        || fail "GIO-Modulpfad konnte nicht relociert werden: $module"
done
for library in "$APPDIR/usr/lib/libproxy.so.1" "$APPDIR/usr/lib/libpxbackend-1.0.so"; do
    [ -f "$library" ] || continue
    patchelf --set-rpath '$ORIGIN' "$library" \
        || fail "Proxy-Bibliothekspfad konnte nicht relociert werden: $library"
done

# Plugins liegen im finalen AppDir unter usr/lib/dino/plugins; der
# Multiarch-Pfad wird im nächsten Schritt nur als Symlink darauf angelegt.
# Halte sowohl die DinoX-Bibliotheken als auch den privaten WebRTC-Wrapper
# paketrelativ auflösbar, ohne AppRun/LD_LIBRARY_PATH vorauszusetzen.
for plugin in "$APPDIR/usr/lib/dino/plugins/"*.so; do
    [ -f "$plugin" ] && patchelf --set-rpath \
        "\$ORIGIN:\$ORIGIN/../..:\$ORIGIN/../../dinox:\$ORIGIN/../../../dinox" \
        "$plugin" 2>/dev/null || true
done
echo "  OK Plugins gepatcht"

# ── Schritt 9b: Symlink für hardcodierten Pluginpfad ────────────────────────
step "Schritt 9b: Pluginpfad-Symlink setzen"

# libdino.so.0 hat /usr/lib/<multiarch>/dino/plugins hardcodiert (Multiarch)
# Plugins liegen aber in /usr/lib/dino/plugins
# Symlink: <multiarch>/dino -> ../../lib/dino
mkdir -p "$APPDIR/usr/lib/$TRIPLET"
rm -rf "$APPDIR/usr/lib/$TRIPLET/dino"
ln -sf "../../lib/dino" "$APPDIR/usr/lib/$TRIPLET/dino"

# Prüfen ob Symlink korrekt aufgelöst wird
if [ -d "$APPDIR/usr/lib/$TRIPLET/dino/plugins" ]; then
    echo "  OK Symlink funktioniert — Plugins sichtbar:"
    ls "$APPDIR/usr/lib/$TRIPLET/dino/plugins/"
else
    echo "  FEHLER: Symlink wird nicht aufgelöst!"
    ls -la "$APPDIR/usr/lib/$TRIPLET/" || true
fi

# ── Schritt 10: Blacklist anwenden ───────────────────────────────────────────
step "Schritt 10: System-Libs entfernen (Blacklist)"
apply_blacklist "$APPDIR/usr/lib"
for elf in \
        "$APPDIR/usr/bin/tor" \
        "$APPDIR/usr/bin/lyrebird" \
        "$APPDIR/usr/bin/gpg" \
        "$APPDIR/usr/bin/gpgconf" \
        "$APPDIR/usr/bin/gpg-agent" \
        "$APPDIR/usr/bin/dirmngr" \
        "$APPDIR/usr/bin/gpg-connect-agent" \
        "$APPDIR/usr/bin/curl" \
        "$CUSTOM_LIBDIR"/libmosquitto.so* \
        "$CUSTOM_LIBDIR"/libcjson.so*; do
    if [ -e "$elf" ] && LD_LIBRARY_PATH="$CUSTOM_LIBDIR:$APPDIR/usr/lib/$TRIPLET:$APPDIR/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$elf" 2>/dev/null | grep "not found" >/dev/null; then
        LD_LIBRARY_PATH="$CUSTOM_LIBDIR:$APPDIR/usr/lib/$TRIPLET:$APPDIR/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$elf" >&2 || true
        fail "ungeloeste Runtime-Abhaengigkeiten fuer $(basename "$elf")"
    fi
done

# ── Schritt 11: AppRun ───────────────────────────────────────────────────────
step "Schritt 11: AppRun erstellen"

cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/bash
# AppRun — DinoX AppImage Einstiegspunkt
APPDIR="$(dirname "$(readlink -f "$0")")"
export APPDIR
export APPIMAGE="${APPIMAGE:-$0}"
export PATH="${APPDIR}/usr/bin:${PATH:-/usr/bin:/bin}"

dinox_accessibility_bus_is_healthy() {
    local address="$1"
    [ -n "$address" ] || return 1
    command -v gdbus >/dev/null 2>&1 || return 1
    command -v timeout >/dev/null 2>&1 || return 1

    timeout 2 gdbus call --address "$address" \
        --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.ListNames >/dev/null 2>&1
}

dinox_accessibility_bus_address() {
    timeout 2 gdbus call --session --dest org.a11y.Bus \
        --object-path /org/a11y/bus \
        --method org.a11y.Bus.GetAddress 2>/dev/null \
        | sed -n "s/.*'\\([^']*\\)'.*/\\1/p" || true
}

dinox_repair_accessibility_bus() {
    [ "${DINOX_DISABLE_A11Y_BUS_REPAIR:-}" = "1" ] && return 0
    [ -n "${NO_AT_BRIDGE:-}" ] && return 0
    [ -n "${FLATPAK_ID:-}" ] && return 0
    [ -n "${XDG_RUNTIME_DIR:-}" ] || return 0
    [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || return 0

    local address=""
    local can_probe=false
    if command -v gdbus >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
        can_probe=true
        address="$(dinox_accessibility_bus_address)"
        dinox_accessibility_bus_is_healthy "$address" && return 0
    elif [ -S "${XDG_RUNTIME_DIR}/at-spi/bus_0" ]; then
        return 0
    fi

    [ "${DINOX_REPAIR_A11Y_BUS:-}" = "1" ] || return 0

    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user restart at-spi-dbus-bus.service >/dev/null 2>&1 || true
        sleep 0.2
        if [ "$can_probe" = true ]; then
            address="$(dinox_accessibility_bus_address)"
            dinox_accessibility_bus_is_healthy "$address" && return 0
        else
            return 0
        fi
    fi

    [ "$can_probe" = true ] || return 0
    if command -v pgrep >/dev/null 2>&1; then
        local -a pids=()
        mapfile -t pids < <({
            pgrep -u "$(id -u)" -f '/usr/libexec/[a]t-spi-bus-launcher' || true
            pgrep -u "$(id -u)" -f '/usr/bin/[d]bus-daemon .*at-spi2/accessibility.conf' || true
            pgrep -u "$(id -u)" -f '(^|/)[a]t-spi2-registryd( |$)' || true
        } | sort -u)
        if [ "${#pids[@]}" -gt 0 ]; then
            kill "${pids[@]}" >/dev/null 2>&1 || true
            sleep 0.5
            address="$(dinox_accessibility_bus_address)"
            dinox_accessibility_bus_is_healthy "$address" || true
        fi
    fi
}

# Eigene Bibliotheken (SQLCipher, libomemo-c, libnice, libmosquitto etc.)
# Debian-Multiarch-Pfad nötig für libdino.so.0, libcrypto-vala.so.0, libxmpp-vala.so.0
export LD_LIBRARY_PATH="${APPDIR}/usr/lib/dinox:${APPDIR}/usr/lib/__DINOX_TRIPLET__:${APPDIR}/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# All in-process modules must match the bundled GLib/GTK/GStreamer libraries.
# EXTRA_MODULES alone still scans the host directory and causes ABI failures.
export GIO_MODULE_DIR="${APPDIR}/usr/lib/gio/modules"
unset GIO_EXTRA_MODULES
export GTK_EXE_PREFIX="${APPDIR}/usr"
export GTK_PATH="${APPDIR}/usr/lib/gtk-4.0"
export LIBHEIF_PLUGIN_PATH="${APPDIR}/usr/lib/libheif/plugins"
export DINOX_CANBERRA_MODULE_DIR="${APPDIR}/usr/lib/dinox/canberra"
export OPENSSL_MODULES="${APPDIR}/usr/lib/ossl-modules"
export OPENSSL_ENGINES="${APPDIR}/usr/lib/engines-3"

# GStreamer — gebündelte Plugins + Scanner
export GST_PLUGIN_PATH="${APPDIR}/usr/lib/gstreamer-1.0"
export GST_PLUGIN_SYSTEM_PATH="${APPDIR}/usr/lib/gstreamer-1.0"
export GST_PLUGIN_PATH_1_0="$GST_PLUGIN_PATH"
export GST_PLUGIN_SYSTEM_PATH_1_0="$GST_PLUGIN_SYSTEM_PATH"
if [ -f "${APPDIR}/usr/lib/gstreamer-1.0/gst-plugin-scanner" ]; then
    export GST_PLUGIN_SCANNER="${APPDIR}/usr/lib/gstreamer-1.0/gst-plugin-scanner"
    export GST_PLUGIN_SCANNER_1_0="$GST_PLUGIN_SCANNER"
fi

# XDG / GLib
export XDG_DATA_DIRS="${APPDIR}/usr/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}:/usr/local/share:/usr/share"
export GSETTINGS_SCHEMA_DIR="${APPDIR}/usr/share/glib-2.0/schemas"
if [ -d "${APPDIR}/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders" ]; then
    export GDK_PIXBUF_MODULEDIR="${APPDIR}/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders"
    PIXBUF_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/dinox/gdk-pixbuf-loaders.cache"
    if [ -x "${APPDIR}/usr/bin/gdk-pixbuf-query-loaders" ]; then
        mkdir -p "$(dirname "$PIXBUF_CACHE")"
        if GDK_PIXBUF_MODULEDIR="$GDK_PIXBUF_MODULEDIR" "${APPDIR}/usr/bin/gdk-pixbuf-query-loaders" > "$PIXBUF_CACHE" 2>/dev/null; then
            export GDK_PIXBUF_MODULE_FILE="$PIXBUF_CACHE"
        else
            echo "DinoX: Could not create the bundled image-loader cache: $PIXBUF_CACHE" >&2
            exit 1
        fi
    else
        echo "DinoX: The AppImage is missing gdk-pixbuf-query-loaders." >&2
        exit 1
    fi
fi

# Desktop integration hints for direct AppImage launches. Some panels/docks
# cannot resolve theme icons inside an uninstalled AppImage and otherwise show
# a generic gear icon. Make the icon name discoverable from the user's hicolor
# theme too; this is harmless if Deb/Flatpak already installed the same icon.
USER_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
USER_ICON_BASE="${USER_DATA_HOME}/icons/hicolor"
for size in 16 32 48 128 256 512; do
    src="${APPDIR}/usr/share/icons/hicolor/${size}x${size}/apps/im.dinox.dinox.png"
    dest_dir="${USER_ICON_BASE}/${size}x${size}/apps"
    if [ -f "$src" ]; then
        mkdir -p "$dest_dir"
        cp -f "$src" "${dest_dir}/im.dinox.dinox.png" 2>/dev/null || true
    fi
done
if [ -f "${APPDIR}/usr/share/icons/hicolor/scalable/apps/im.dinox.dinox.svg" ]; then
    mkdir -p "${USER_ICON_BASE}/scalable/apps"
    cp -f "${APPDIR}/usr/share/icons/hicolor/scalable/apps/im.dinox.dinox.svg" \
        "${USER_ICON_BASE}/scalable/apps/im.dinox.dinox.svg" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f "${USER_ICON_BASE}" >/dev/null 2>&1 || true
fi

# Point launch-aware shells at a desktop file with an absolute icon path.
DESKTOP_HINT_DIR="${XDG_RUNTIME_DIR:-/tmp}/dinox"
mkdir -p "${DESKTOP_HINT_DIR}"
DESKTOP_HINT_FILE="${DESKTOP_HINT_DIR}/im.dinox.dinox-appimage.desktop"
sed \
    -e "s|^Icon=im.dinox.dinox$|Icon=${APPDIR}/im.dinox.dinox.png|" \
    -e "s|^Exec=dinox %U$|Exec=\"${APPDIR}/AppRun\" %U|" \
    "${APPDIR}/im.dinox.dinox.desktop" > "${DESKTOP_HINT_FILE}" 2>/dev/null \
    || DESKTOP_HINT_FILE="${APPDIR}/im.dinox.dinox.desktop"
export GIO_LAUNCHED_DESKTOP_FILE="${DESKTOP_HINT_FILE}"
export GIO_LAUNCHED_DESKTOP_FILE_PID="$$"
export BAMF_DESKTOP_FILE_HINT="${DESKTOP_HINT_FILE}"

# DinoX Plugin-Pfad — DINO_PLUGIN_DIR ist die korrekte Variable (siehe util.vala)
export DINO_PLUGIN_DIR="${APPDIR}/usr/lib/__DINOX_TRIPLET__/dino/plugins"

# Tor / Lyrebird
export DINOX_TOR_PATH="${APPDIR}/usr/bin/tor"
export DINOX_LYREBIRD_PATH="${APPDIR}/usr/bin/lyrebird"
export DINOX_TOR_DATA_DIR="${APPDIR}/usr/share/dinox/tor"

# GTK Input Method — auf KDE/XFCE kann fcitx/ibus Probleme machen
case "${DESKTOP_SESSION:-}" in
    gnome*|unity*|budgie*) ;;
    *) unset GTK_IM_MODULE ;;
esac

# CA-Zertifikate — GnuTLS Debian-Pfad existiert auf anderen Distros nicht
if [ -z "${GTLS_SYSTEM_CA_FILE:-}" ]; then
    for ca in \
        /etc/ssl/certs/ca-certificates.crt \
        /etc/pki/tls/certs/ca-bundle.crt \
        /etc/ssl/ca-bundle.pem \
        /var/lib/ca-certificates/ca-bundle.pem \
        /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
        /etc/ssl/cert.pem; do
        [ -f "$ca" ] && export GTLS_SYSTEM_CA_FILE="$ca" && break
    done
fi
if [ -n "${GTLS_SYSTEM_CA_FILE:-}" ]; then
    [ -n "${SSL_CERT_FILE:-}" ] || export SSL_CERT_FILE="$GTLS_SYSTEM_CA_FILE"
    [ -n "${CURL_CA_BUNDLE:-}" ] || export CURL_CA_BUNDLE="$GTLS_SYSTEM_CA_FILE"
fi

# Übersetzungen — TEXTDOMAINDIR wird von get_locale_path() in util.vala ausgewertet
export TEXTDOMAINDIR="${APPDIR}/usr/share/locale"

# Sprachdatei beim ersten Start anlegen
LANG_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/dinox/language"
if [ ! -f "$LANG_FILE" ]; then
    mkdir -p "$(dirname "$LANG_FILE")"
    echo "system" > "$LANG_FILE"
fi

dinox_repair_accessibility_bus
exec "${APPDIR}/usr/bin/dinox" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"
sed -i "s|__DINOX_TRIPLET__|$TRIPLET|g" "$APPDIR/AppRun"
echo "  OK AppRun erstellt"

# Stage the exact license material for project, custom and distribution-owned
# files only after the blacklist has removed entries not shipped in AppDir.
step "Schritt 11a: Lizenz- und Komponentenmaterial"
bash "$PROJECT_ROOT/scripts/stage-package-licenses.sh" \
    --mode appimage \
    --root "$APPDIR" \
    --source-map "$LICENSE_SOURCE_MAP" \
    --project-map "$PROJECT_INSTALL_MAP"
rm -f "$LICENSE_SOURCE_MAP"
LICENSE_SOURCE_MAP=""
rm -f "$PROJECT_INSTALL_MAP"
PROJECT_INSTALL_MAP=""

# Validate the complete AppDir while every exact corresponding-source payload is
# still present. GStreamer and ELF validation remain static and never start a
# GStreamer plugin scanner in Forgejo/DIND.
step "Schritt 11b: Vollständige AppDir Runtime-/Source-Matrix prüfen"
"$PROJECT_ROOT/scripts/package-runtime-matrix.sh" appdir-full "$APPDIR"

# Seal the complete license/compliance tree as a mandatory release sidecar.
# Only the payloads recorded in SOURCE_PAYLOADS.tsv are removed afterwards;
# notices, licenses, exact metadata, the inventory and the source offer remain
# in the slim AppImage.
step "Schritt 11c: AppImage Source-Sidecar versiegeln"
cd "$PROJECT_ROOT"
CORRESPONDING_SOURCE_BUNDLE="${OUTPUT}.sources.tar.xz"
SOURCE_BUNDLE_BASENAME="$(basename -- "$CORRESPONDING_SOURCE_BUNDLE")"
SOURCE_BUNDLE_ROOT="$APPDIR/usr/share/licenses/dinox"
SOURCE_PAYLOAD_INVENTORY="$SOURCE_BUNDLE_ROOT/SOURCE_PAYLOADS.tsv"
SOURCE_OFFER="$SOURCE_BUNDLE_ROOT/SOURCE_OFFER.md"
SOURCE_BUNDLE_CHECKSUM="$SOURCE_BUNDLE_ROOT/SOURCE_BUNDLE.sha256"
rm -f \
    "$OUTPUT" "${OUTPUT}.zsync" "${OUTPUT}.sha256" \
    "$CORRESPONDING_SOURCE_BUNDLE" "${CORRESPONDING_SOURCE_BUNDLE}.sha256" \
    "$SOURCE_PAYLOAD_INVENTORY" "$SOURCE_OFFER" "$SOURCE_BUNDLE_CHECKSUM"

create_source_payload_inventory "$SOURCE_BUNDLE_ROOT"
{
    printf '# DinoX AppImage corresponding sources\n\n'
    printf 'The complete corresponding-source and license tree for this exact '
    printf 'AppImage build is published beside the AppImage.\n\n'
    printf 'source_bundle=%s\n' "$SOURCE_BUNDLE_BASENAME"
    printf 'payload_inventory=SOURCE_PAYLOADS.tsv\n'
    printf 'bundle_checksum=SOURCE_BUNDLE.sha256\n'
} > "$SOURCE_OFFER"
chmod 0644 "$SOURCE_OFFER"
validate_license_tree_paths "$SOURCE_BUNDLE_ROOT"

PACKAGE_SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$PROJECT_ROOT" log -1 --format=%ct 2>/dev/null || printf '0')}"
tar \
    --sort=name \
    --mtime="@$PACKAGE_SOURCE_DATE_EPOCH" \
    --owner=0 --group=0 --numeric-owner \
    -cJf "$CORRESPONDING_SOURCE_BUNDLE" \
    -C "$SOURCE_BUNDLE_ROOT" \
    .

EXPECTED_SOURCE_BUNDLE_LISTING="$(mktemp "$TOOLS_DIR/appimage-source-expected.XXXXXX")"
SOURCE_BUNDLE_LISTING="$(mktemp "$TOOLS_DIR/appimage-source-archive.XXXXXX")"
(
    cd "$SOURCE_BUNDLE_ROOT"
    find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort
) > "$EXPECTED_SOURCE_BUNDLE_LISTING"
while IFS= read -r archived_path; do
    case "$archived_path" in
        .|./) continue ;;
    esac
    archived_path="${archived_path#./}"
    archived_path="${archived_path%/}"
    safe_license_relative_path "$archived_path" \
        || fail "unsicherer Pfad im AppImage Source-Sidecar: $archived_path"
    printf '%s\n' "$archived_path"
done < <(tar -tJf "$CORRESPONDING_SOURCE_BUNDLE") \
    | LC_ALL=C sort > "$SOURCE_BUNDLE_LISTING"
while IFS= read -r archive_entry; do
    case "${archive_entry:0:1}" in
        -|d) ;;
        *) fail "AppImage Source-Sidecar enthält einen Link oder eine Spezialdatei" ;;
    esac
done < <(tar -tvJf "$CORRESPONDING_SOURCE_BUNDLE")
[ "$(wc -l < "$SOURCE_BUNDLE_LISTING")" -eq \
    "$(LC_ALL=C sort -u "$SOURCE_BUNDLE_LISTING" | wc -l)" ] \
    || fail "AppImage Source-Sidecar enthält doppelte Archivpfade"
cmp -s "$EXPECTED_SOURCE_BUNDLE_LISTING" "$SOURCE_BUNDLE_LISTING" \
    || fail "AppImage Source-Sidecar weicht vom vollständigen Lizenz-/Quellbaum ab"
rm -f "$EXPECTED_SOURCE_BUNDLE_LISTING" "$SOURCE_BUNDLE_LISTING"

SOURCE_BUNDLE_SHA256="$(sha256sum -- "$CORRESPONDING_SOURCE_BUNDLE" | awk '{ print $1 }')"
printf '%s  %s\n' "$SOURCE_BUNDLE_SHA256" "$SOURCE_BUNDLE_BASENAME" \
    > "${CORRESPONDING_SOURCE_BUNDLE}.sha256.tmp"
mv "${CORRESPONDING_SOURCE_BUNDLE}.sha256.tmp" "${CORRESPONDING_SOURCE_BUNDLE}.sha256"
chmod 0644 "${CORRESPONDING_SOURCE_BUNDLE}.sha256"
(cd "$PROJECT_ROOT" && sha256sum -c "$(basename -- "${CORRESPONDING_SOURCE_BUNDLE}.sha256")")
install -m 0644 "${CORRESPONDING_SOURCE_BUNDLE}.sha256" "$SOURCE_BUNDLE_CHECKSUM"
cmp -s "${CORRESPONDING_SOURCE_BUNDLE}.sha256" "$SOURCE_BUNDLE_CHECKSUM" \
    || fail "AppDir Source-Bundle-Prüfsumme weicht vom Release-Sidecar ab"

# Validate the actual extracted sidecar, not merely the pre-archive input tree.
# The archive stores the license tree directly, with no additional top-level
# directory, so Forgejo can compare it to an extracted AppImage using the same
# appdir-provenance mode.
SOURCE_EXTRACT_DIR="$(mktemp -d "$TOOLS_DIR/appimage-source-extracted.XXXXXX")"
tar \
    --extract --xz \
    --file "$CORRESPONDING_SOURCE_BUNDLE" \
    --directory "$SOURCE_EXTRACT_DIR" \
    --no-same-owner --no-same-permissions
validate_license_tree_paths "$SOURCE_EXTRACT_DIR"

remove_inventoried_source_payloads "$SOURCE_BUNDLE_ROOT"
"$PROJECT_ROOT/scripts/package-runtime-matrix.sh" \
    appdir-provenance "$APPDIR" "$SOURCE_EXTRACT_DIR"

step "Schritt 11d: Schlanke AppDir Runtime-/Source-Offer-Matrix prüfen"
"$PROJECT_ROOT/scripts/package-runtime-matrix.sh" appdir "$APPDIR"
rm -rf "$SOURCE_EXTRACT_DIR"
SOURCE_EXTRACT_DIR=""

# ── Schritt 12: AppImage bauen ───────────────────────────────────────────────
step "Schritt 12: Schlankes AppImage bauen"

export ARCH="$ARCH"
export APPIMAGE_EXTRACT_AND_RUN=1

APPIMAGETOOL_ARGS=(-v --comp zstd "${APPIMAGETOOL_RUNTIME_ARGS[@]}")
if [ -n "${APPIMAGE_UPDATE_INFO:-}" ]; then
    APPIMAGETOOL_ARGS+=(--updateinformation "$APPIMAGE_UPDATE_INFO")
fi

if ! "$APPIMAGETOOL" "${APPIMAGETOOL_ARGS[@]}" "$APPDIR" "$OUTPUT"; then
    fail "appimagetool fehlgeschlagen!"
fi

sha256sum "$OUTPUT" > "${OUTPUT}.sha256.tmp"
mv "${OUTPUT}.sha256.tmp" "${OUTPUT}.sha256"
sha256sum -c "${OUTPUT}.sha256"

echo ""
echo "======================================================="
echo "  OK $OUTPUT"
echo "  Groesse:  $(du -sh "$OUTPUT" | cut -f1)"
echo "  SHA256: $(cut -d' ' -f1 "${OUTPUT}.sha256")"
echo "  Sources: $CORRESPONDING_SOURCE_BUNDLE"
[ -f "${OUTPUT}.zsync" ] && echo "  OK Delta-Updates (zsync) aktiv"
echo "======================================================="
echo ""
echo "  Testen:      chmod +x $OUTPUT && ./$OUTPUT"
echo "  Installieren: mv $OUTPUT ~/Applications/"
