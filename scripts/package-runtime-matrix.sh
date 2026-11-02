#!/usr/bin/env bash
set -euo pipefail

# Diagnose the runtime surface that matters for DinoX packages.
# The local/system build is the reference.  Packaging jobs call this script for
# system, deb, AppDir and Flatpak manifest checks so regressions are visible in
# Forgejo logs before a user installs the artifact.

MODE="${1:-system}"
TARGET="${2:-}"
SOURCE_TARGET="${3:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ok_count=0
warn_count=0
fail_count=0
GST_INSPECT_TIMEOUT="${GST_INSPECT_TIMEOUT:-15}"
GST_CHECK_MODE="inspect"
GST_STATIC_PLUGIN_DIR=""
FFMPEG_RECORDER_VERSION="8.1.2"
FFMPEG_RECORDER_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
LIBVA_SOURCE_SHA256="117f8d658a5fc9ea406ca80a3eb4ae1d70b15a54807c9ed77199c812bed73b60"
X264_RECORDER_COMMIT="b35605ace3ddf7c1a5d67a2eb553f034aef41d55"
X264_RECORDER_SHA256="cd71a7515b0e9a012e1ac9b1f8415bebcaf6fc97d4db32286642ac4c0fbe24f9"
GNUPG_REQUIRED_SERIES="2.4"
IBUS_COMPAT_SOURCE_SHA256="05b84d4a45139face161596e5ade8e6c5da55cfaf6f194861da66516190f5b96"
AT_SPI_REGISTRY_PGREP_PATTERN="[a]t-spi2-registryd"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*"; }

usage() {
    echo "Usage: $0 {system [BUILD_DIR]|local [BUILD_DIR]|deb [file.deb]|appdir [AppDir]|appdir-full [AppDir]|appdir-provenance AppDir LICENSE_ROOT|flatpak-manifest [manifest.json]|metadata|self-test}"
}

validate_args() {
    case "$MODE" in
        -h|--help|help)
            if [ "$#" -gt 1 ]; then
                red "Zu viele Argumente: $*"
                usage
                exit 2
            fi
            ;;
        metadata|self-test)
            if [ "$#" -gt 1 ]; then
                red "Modus $MODE akzeptiert kein Zielargument: $2"
                usage
                exit 2
            fi
            ;;
        system|local|deb|appdir|appdir-full|flatpak-manifest)
            if [ "$#" -gt 2 ]; then
                red "Zu viele Argumente: $*"
                usage
                exit 2
            fi
            ;;
        appdir-provenance)
            if [ "$#" -ne 3 ]; then
                red "Modus appdir-provenance benötigt AppDir und extrahierten Lizenzbaum"
                usage
                exit 2
            fi
            ;;
    esac
}

validate_args "$@"

row_ok() {
    printf '  [OK]   %s\n' "$1"
    ok_count=$((ok_count + 1))
}

row_warn() {
    printf '  [WARN] %s\n' "$1"
    warn_count=$((warn_count + 1))
}

row_info() {
    printf '  [INFO] %s\n' "$1"
}

row_fail() {
    printf '  [FAIL] %s\n' "$1"
    fail_count=$((fail_count + 1))
}

section() {
    echo
    echo "== $1 =="
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

run_isolated_git() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git "$@"
}

run_gst_inspect() {
    local element="$1"
    # Keep package diagnostics from spawning gst-plugin-scanner.  In Forgejo/DIND
    # the scanner can block in uninterruptible sleep, which survives job timeout
    # and keeps host load high.  In-process inspection is enough for diagnostics.
    if have_cmd timeout; then
        env GST_REGISTRY_FORK=no timeout --kill-after=5s "${GST_INSPECT_TIMEOUT}s" \
            gst-inspect-1.0 "$element" >/dev/null 2>&1
    else
        env GST_REGISTRY_FORK=no gst-inspect-1.0 "$element" >/dev/null 2>&1
    fi
}

live_gstreamer_diagnostics_allowed() {
    if [ "${DINOX_ALLOW_LIVE_GSTREAMER_DIAGNOSTICS:-}" = "1" ]; then
        return 0
    fi
    [ -z "${CI:-}" ] && [ -z "${GITHUB_ACTIONS:-}" ] && [ -z "${FORGEJO_ACTIONS:-}" ] && [ -z "${DINOX_CI:-}" ]
}

check_file() {
    local path="$1" label="${2:-$1}" required="${3:-true}"
    if [ -e "$path" ]; then
        row_ok "$label"
    elif [ "$required" = "true" ]; then
        row_fail "$label fehlt ($path)"
    else
        row_warn "$label fehlt ($path)"
    fi
}

check_nonempty_file() {
    local path="$1" label="${2:-$1}"
    if [ -s "$path" ]; then
        row_ok "$label"
    else
        row_fail "$label fehlt oder ist leer ($path)"
    fi
}

check_file_sha256() {
    local path="$1" expected="$2" label="$3"
    local actual

    if [ ! -s "$path" ]; then
        return
    fi
    if ! have_cmd sha256sum; then
        row_fail "$label nicht geprüft; sha256sum fehlt"
        return
    fi
    actual="$(sha256sum "$path" | awk '{print $1}')"
    if [ "$actual" = "$expected" ]; then
        row_ok "$label"
    else
        row_fail "$label falsch ($actual != $expected)"
    fi
}

check_file_contains() {
    local path="$1" pattern="$2" label="$3"
    [ -f "$path" ] || return 0
    if grep -qF -- "$pattern" "$path"; then
        row_ok "$label"
    else
        row_fail "$label fehlt ($pattern)"
    fi
}

check_file_lacks() {
    local path="$1" pattern="$2" label="$3"
    [ -f "$path" ] || return 0
    if grep -qF -- "$pattern" "$path"; then
        row_fail "$label unerwartet vorhanden ($pattern)"
    else
        row_ok "$label"
    fi
}

check_symlink_target() {
    local path="$1" expected="$2" label="$3"
    local actual

    if [ ! -L "$path" ]; then
        row_fail "$label ungültig ($path ist kein Symlink)"
        return
    fi

    actual="$(readlink "$path")"
    if [ "$actual" = "$expected" ]; then
        row_ok "$label"
    else
        row_fail "$label ungültig ($actual != $expected)"
    fi
}

check_files_equal() {
    local left="$1" right="$2" label="$3"
    [ -f "$left" ] || return 0
    [ -f "$right" ] || return 0

    if cmp -s "$left" "$right"; then
        row_ok "$label"
    else
        row_fail "$label unterschiedlich"
    fi
}

check_deb_file_contains() {
    local deb="$1" path="$2" pattern="$3" label="$4"
    local tar_path=".$path"
    local file_contents

    if ! file_contents="$(dpkg-deb --fsys-tarfile "$deb" | tar -xOf - "$tar_path" 2>/dev/null)"; then
        row_fail "$label nicht lesbar ($path)"
        return
    fi

    if grep -qF -- "$pattern" <<< "$file_contents"; then
        row_ok "$label"
    else
        row_fail "$label fehlt ($pattern)"
    fi
}

check_deb_file_lacks() {
    local deb="$1" path="$2" pattern="$3" label="$4"
    local tar_path=".$path"
    local file_contents

    if ! file_contents="$(dpkg-deb --fsys-tarfile "$deb" | tar -xOf - "$tar_path" 2>/dev/null)"; then
        row_fail "$label nicht lesbar ($path)"
        return
    fi

    if grep -qF -- "$pattern" <<< "$file_contents"; then
        row_fail "$label unerwartet vorhanden ($pattern)"
    else
        row_ok "$label"
    fi
}

check_deb_appstream_file() {
    local deb="$1" path="$2" label="$3"
    local tar_path=".$path"
    local tmp_file

    tmp_file="$(mktemp)"
    if ! dpkg-deb --fsys-tarfile "$deb" | tar -xOf - "$tar_path" > "$tmp_file" 2>/dev/null; then
        rm -f "$tmp_file"
        row_fail "$label nicht lesbar ($path)"
        return
    fi

    check_appstream_file "$tmp_file" "$label" false
    rm -f "$tmp_file"
}

check_deb_desktop_file() {
    local deb="$1" path="$2" label="$3"
    local tar_path=".$path"
    local tmp_file

    tmp_file="$(mktemp --suffix=.desktop)"
    if ! dpkg-deb --fsys-tarfile "$deb" | tar -xOf - "$tar_path" > "$tmp_file" 2>/dev/null; then
        rm -f "$tmp_file"
        row_fail "$label nicht lesbar ($path)"
        return
    fi

    check_desktop_file "$tmp_file" "$label"
    rm -f "$tmp_file"
}

check_glob() {
    local pattern="$1" label="$2" required="${3:-true}"
    shopt -s nullglob
    local matches=( $pattern )
    shopt -u nullglob
    if [ "${#matches[@]}" -gt 0 ]; then
        row_ok "$label (${#matches[@]})"
    elif [ "$required" = "true" ]; then
        row_fail "$label fehlt ($pattern)"
    else
        row_warn "$label fehlt ($pattern)"
    fi
}

check_glob_absent() {
    local pattern="$1" label="$2"
    # nullglob does not remove a missing literal path without wildcard syntax.
    # Count real entries explicitly, including dangling aliases, and retain
    # spaces in the supplied path while still expanding wildcard patterns.
    local IFS=''
    local matches=( $pattern )
    local match matched_count=0
    for match in "${matches[@]}"; do
        if [ -e "$match" ] || [ -L "$match" ]; then
            matched_count=$((matched_count + 1))
        fi
    done
    if [ "$matched_count" -eq 0 ]; then
        row_ok "$label nicht gebündelt"
    else
        row_fail "$label unerwartet gebündelt ($matched_count)"
    fi
}

check_single_library_payload() {
    local root="$1" pattern="$2" label="$3"
    local path real
    declare -A payloads=()

    while IFS= read -r -d '' path; do
        real="$(readlink -f "$path" 2>/dev/null || true)"
        [ -n "$real" ] && payloads["$real"]=1
    done < <(find "$root" -name "$pattern" \( -type f -o -type l \) -print0 2>/dev/null)

    if [ "${#payloads[@]}" -eq 1 ]; then
        row_ok "$label genau eine Implementierung"
    elif [ "${#payloads[@]}" -eq 0 ]; then
        row_fail "$label keine Implementierung gefunden"
    else
        row_fail "$label mehrere Implementierungen gefunden (${#payloads[@]})"
        printf '    %s\n' "${!payloads[@]}" | sort
    fi
}

check_glob_any() {
    local label="$1"
    shift
    local count=0
    local pattern matches
    shopt -s nullglob
    for pattern in "$@"; do
        matches=( $pattern )
        count=$((count + ${#matches[@]}))
    done
    shopt -u nullglob
    if [ "$count" -gt 0 ]; then
        row_ok "$label ($count)"
    else
        row_fail "$label fehlt ($*)"
    fi
}

production_plugin_names() {
    cat <<'EOF'
google-webrtc.so
http-files.so
ice.so
notification-sound.so
omemo.so
openpgp.so
mqtt.so
libtor-manager.so
bot-features.so
EOF
}

translation_catalog_domains() {
    cat <<'EOF'
dino|main/po/LINGUAS
dino-omemo|plugins/omemo/po/LINGUAS
dino-openpgp|plugins/openpgp/po/LINGUAS
EOF
}

production_plugin_inventory_issues() {
    local root="$1"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local plugin path
    local -a matches=()
    local issues=0

    if ! command -v "$readelf_cmd" >/dev/null 2>&1; then
        printf 'readelf fehlt; Produktionsplugins können nicht validiert werden\n'
        return 1
    fi

    while IFS= read -r plugin; do
        matches=()
        while IFS= read -r -d '' path; do
            matches+=( "$path" )
        done < <(
            find "$root/usr/lib" -type f \
                -path "*/dino/plugins/$plugin" -size +0c -print0 2>/dev/null
        )

        if [ "${#matches[@]}" -ne 1 ]; then
            printf '%s: genau ein Linux-Paketplugin erwartet, gefunden: %s\n' \
                "$plugin" "${#matches[@]}"
            issues=1
            continue
        fi
        if ! LC_ALL=C "$readelf_cmd" -h "${matches[0]}" >/dev/null 2>&1; then
            printf '%s: Paketdatei ist kein lesbares ELF-Plugin (%s)\n' \
                "$plugin" "${matches[0]#"$root"/}"
            issues=1
        fi
    done < <(production_plugin_names)

    return "$issues"
}

check_production_plugin_inventory() {
    local root="$1" label="$2"
    local output rc=0

    output="$(production_plugin_inventory_issues "$root")" || rc=$?
    if [ "$rc" -eq 0 ]; then
        row_ok "$label (9 Linux-Plugins)"
    else
        row_fail "$label unvollständig oder ungültig"
        sed 's/^/    /' <<< "$output"
    fi
}

translation_catalog_inventory_issues() {
    local root="$1"
    local source_root="${2:-$PROJECT_ROOT}"
    local domain linguas_relative linguas_file line language catalog
    local language_count
    local issues=0

    while IFS='|' read -r domain linguas_relative; do
        linguas_file="$source_root/$linguas_relative"
        if [ ! -s "$linguas_file" ]; then
            printf '%s: Checkout-LINGUAS fehlt oder ist leer (%s)\n' \
                "$domain" "$linguas_relative"
            issues=1
            continue
        fi

        language_count=0
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            for language in $line; do
                language_count=$((language_count + 1))
                catalog="$root/usr/share/locale/$language/LC_MESSAGES/$domain.mo"
                if [ ! -s "$catalog" ]; then
                    printf '%s: Katalog für %s fehlt oder ist leer (%s)\n' \
                        "$domain" "$language" "${catalog#"$root"/}"
                    issues=1
                fi
            done
        done < "$linguas_file"

        if [ "$language_count" -eq 0 ]; then
            printf '%s: Checkout-LINGUAS enthält keine Sprachen (%s)\n' \
                "$domain" "$linguas_relative"
            issues=1
        fi
    done < <(translation_catalog_domains)

    return "$issues"
}

check_translation_catalog_inventory() {
    local root="$1" label="$2"
    local output rc=0

    output="$(translation_catalog_inventory_issues "$root" "$PROJECT_ROOT")" || rc=$?
    if [ "$rc" -eq 0 ]; then
        row_ok "$label (vollständige Checkout-LINGUAS-Matrix)"
    else
        row_fail "$label unvollständig"
        sed 's/^/    /' <<< "$output"
    fi
}

elf_host_abi_allowed() {
    local profile="$1" soname="$2"

    # AppImages deliberately use the host ABI for the glibc/toolchain boundary,
    # display/audio drivers and the font stack. Keep this list in lock-step with
    # the BLACKLIST in build-appimage.sh; everything else must be in the AppDir.
    case "$soname" in
        linux-vdso.so.*|ld-linux*.so.*|libc.so.*|libm.so.*|libdl.so.*|librt.so.*|libpthread.so.*|libresolv.so.*|libutil.so.*|libnss_*.so.*|\
        libstdc++.so.*|libgcc_s.so.*|\
        libdrm.so.*|libxcb.so.*|libxcb-*.so.*|libX11.so.*|libX11-xcb.so.*|libXext.so.*|libXi.so.*|libXfixes.so.*|libXrender.so.*|libXcursor.so.*|libXdamage.so.*|libXrandr.so.*|libXcomposite.so.*|\
        libwayland-client.so.*|libwayland-server.so.*|libwayland-egl.so.*|libasound.so.*|libpipewire-0.3.so.*|\
        libfontconfig.so.*|libfreetype.so.*|libharfbuzz.so.*|libfribidi.so.*|\
        libcom_err.so.*|libexpat.so.*|libz.so.*|libgmp.so.*|\
        libGL.so.*|libGLX.so.*|libGLdispatch.so.*|libEGL.so.*)
            return 0
            ;;
    esac

    [ "$profile" = "deb" ] || return 1

    # The Debian artifact intentionally consumes these ABIs from declared
    # distro packages (and their transitive dependencies). Project/private
    # ABIs such as libdino, SQLCipher, libomemo-c, libnice, Mosquitto, cJSON,
    # Tor/libevent and the Google/libwebrtc wrapper are intentionally absent
    # here, so a forgotten bundled library remains a hard failure.
    case "$soname" in
        libwayland-cursor.so.*|libadwaita-1.so.*|libgtk-4.so.*|libgdk-4.so.*|libglib-2.0.so.*|libgio-2.0.so.*|libgobject-2.0.so.*|libgmodule-2.0.so.*|libgthread-2.0.so.*|\
        libpango-1.0.so.*|libpangocairo-1.0.so.*|libpangoft2-1.0.so.*|libcairo.so.*|libcairo-gobject.so.*|libgraphene-1.0.so.*|libepoxy.so.*|libpixman-1.so.*|\
        libgdk_pixbuf-2.0.so.*|libjpeg.so.*|libpng*.so.*|libtiff.so.*|libwebp*.so.*|libheif.so.*|libdav1d.so.*|\
        libsoup-3.0.so.*|libsecret-1.so.*|libgcrypt.so.*|libgpgme.so.*|libgee-0.8.so.*|libqrencode.so.*|libcanberra.so.*|libgeoclue-2.so.*|\
        libgstreamer-1.0.so.*|libgstbase-1.0.so.*|libgstapp-1.0.so.*|libgstaudio-1.0.so.*|libgstvideo-1.0.so.*|libgstpbutils-1.0.so.*|libgsttag-1.0.so.*|libgstallocators-1.0.so.*|libgstcontroller-1.0.so.*|libgstnet-1.0.so.*|\
        libavformat.so.*|libswresample.so.*|libswscale.so.*|\
        libssl.so.*|libcrypto.so.*|libunbound.so.8|libsrtp2.so.*|libva.so.*|libva-drm.so.*|libva-x11.so.*|\
        libjson-glib-1.0.so.*|libproxy.so.*|libsqlite3.so.*|libmount.so.*|libselinux.so.*|libpcre2-8.so.*|libffi.so.*|\
        libxml2.so.*|libicuuc.so.*|libicui18n.so.*|libicudata.so.*|libbz2.so.*|liblzma.so.*|libzstd.so.*|libbrotli*.so.*|libnghttp2.so.*|libpsl.so.*|libidn2.so.*|libunistring.so.*|\
        libgnutls.so.*|libnettle.so.*|libhogweed.so.*|libtasn1.so.*|libcap.so.*|libdbus-1.so.*|libsystemd.so.*|libudev.so.*)
            return 0
            ;;
    esac
    return 1
}

elf_dynamic_value() {
    local readelf_cmd="$1" tag="$2" path="$3"
    LC_ALL=C "$readelf_cmd" -d --wide "$path" 2>/dev/null \
        | sed -nE "s/.*\\(${tag}\\).*\\[([^]]+)\\].*/\\1/p"
}

elf_absolute_runtime_path_issues() {
    local requested_root="$1"
    local root
    root="$(readlink -f "$requested_root")"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local path runtime_path_list runtime_path relative
    local -a runtime_paths=()
    local issues=0

    while IFS= read -r -d '' path; do
        LC_ALL=C "$readelf_cmd" -h "$path" >/dev/null 2>&1 || continue
        runtime_path_list="$({
            elf_dynamic_value "$readelf_cmd" RUNPATH "$path"
            elf_dynamic_value "$readelf_cmd" RPATH "$path"
        })"
        while IFS= read -r runtime_path_list; do
            IFS=':' read -r -a runtime_paths <<< "$runtime_path_list"
            for runtime_path in "${runtime_paths[@]}"; do
                case "$runtime_path" in
                    /*)
                        relative="${path#"$root"/}"
                        printf '%s -> %s\n' "$relative" "$runtime_path"
                        issues=1
                        ;;
                esac
            done
        done <<< "$runtime_path_list"
    done < <(find "$root" -type f -print0)

    return "$issues"
}

check_no_absolute_elf_runtime_paths() {
    local root="$1" label="$2"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local output rc=0

    if ! command -v "$readelf_cmd" >/dev/null 2>&1; then
        row_fail "$label nicht geprüft; readelf fehlt"
        return
    fi
    output="$(elf_absolute_runtime_path_issues "$root")" || rc=$?
    if [ "$rc" -eq 0 ]; then
        row_ok "$label (nur relative ELF-Laufzeitpfade)"
    else
        row_fail "$label enthält absolute Build-/Laufzeitpfade"
        sed 's/^/    /' <<< "$output"
    fi
}

bot_features_omemo_resolution_issues() {
    local requested_root="$1"
    local root
    root="$(readlink -f "$requested_root")"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local path bot_features omemo needed runtime_path_list runtime_path relative
    local -a bot_plugins=() runtime_paths=()
    local has_origin=0 issues=0

    while IFS= read -r -d '' path; do
        bot_plugins+=( "$path" )
    done < <(find "$root" -type f -path '*/dino/plugins/bot-features.so' -print0)

    if [ "${#bot_plugins[@]}" -ne 1 ]; then
        printf 'bot-features.so: genau ein Paket-Plugin erwartet, gefunden: %s\n' "${#bot_plugins[@]}"
        return 1
    fi

    bot_features="${bot_plugins[0]}"
    relative="${bot_features#"$root"/}"
    omemo="$(dirname "$bot_features")/omemo.so"
    if ! LC_ALL=C "$readelf_cmd" -h "$bot_features" >/dev/null 2>&1; then
        printf '%s: kein lesbares ELF-Plugin\n' "$relative"
        issues=1
    fi

    needed="$(elf_dynamic_value "$readelf_cmd" NEEDED "$bot_features")"
    if ! grep -Fxq 'omemo.so' <<< "$needed"; then
        printf '%s: DT_NEEDED omemo.so fehlt\n' "$relative"
        issues=1
    fi

    if [ ! -f "$omemo" ] || ! LC_ALL=C "$readelf_cmd" -h "$omemo" >/dev/null 2>&1; then
        printf '%s: gleichgeordnetes omemo.so fehlt oder ist kein lesbares ELF-Plugin\n' "$relative"
        issues=1
    fi

    runtime_path_list="$({
        elf_dynamic_value "$readelf_cmd" RUNPATH "$bot_features"
        elf_dynamic_value "$readelf_cmd" RPATH "$bot_features"
    })"
    while IFS= read -r runtime_path_list; do
        IFS=':' read -r -a runtime_paths <<< "$runtime_path_list"
        for runtime_path in "${runtime_paths[@]}"; do
            case "$runtime_path" in
                '$ORIGIN'|'$ORIGIN/'|'${ORIGIN}'|'${ORIGIN}/')
                    has_origin=1
                    ;;
            esac
        done
    done <<< "$runtime_path_list"
    if [ "$has_origin" -ne 1 ]; then
        printf '%s: DT_RUNPATH/DT_RPATH enthält kein gleichgeordnetes $ORIGIN\n' "$relative"
        issues=1
    fi

    return "$issues"
}

check_bot_features_omemo_resolution() {
    local root="$1" label="$2"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local output rc=0

    if ! command -v "$readelf_cmd" >/dev/null 2>&1; then
        row_fail "$label nicht geprüft; readelf fehlt"
        return
    fi
    output="$(bot_features_omemo_resolution_issues "$root")" || rc=$?
    if [ "$rc" -eq 0 ]; then
        row_ok "$label (DT_NEEDED omemo.so über gleichgeordnetes \$ORIGIN)"
    else
        row_fail "$label nicht relocierbar auflösbar"
        sed 's/^/    /' <<< "$output"
    fi
}

elf_origin_resolves_to_directory() {
    local path="$1" expected_directory="$2"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local runtime_path_list runtime_path suffix resolved
    local -a runtime_paths=()
    local origin_directory expected

    origin_directory="$(readlink -f "$(dirname "$path")")"
    expected="$(readlink -f "$expected_directory")"
    runtime_path_list="$({
        elf_dynamic_value "$readelf_cmd" RUNPATH "$path"
        elf_dynamic_value "$readelf_cmd" RPATH "$path"
    })"
    while IFS= read -r runtime_path_list; do
        IFS=':' read -r -a runtime_paths <<< "$runtime_path_list"
        for runtime_path in "${runtime_paths[@]}"; do
            runtime_path="${runtime_path//'${ORIGIN}'/'$ORIGIN'}"
            case "$runtime_path" in
                '$ORIGIN')
                    suffix=""
                    ;;
                '$ORIGIN/'*)
                    suffix="${runtime_path#\$ORIGIN/}"
                    ;;
                *)
                    continue
                    ;;
            esac
            resolved="$(readlink -m "$origin_directory/${suffix:-.}")"
            [ "$resolved" = "$expected" ] && return 0
        done
    done <<< "$runtime_path_list"
    return 1
}

google_webrtc_runtime_path_issues() {
    local requested_root="$1"
    local root
    root="$(readlink -f "$requested_root")"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local path plugin wrapper worker plugin_libdir needed relative
    local -a plugins=() wrappers=() workers=()
    local issues=0

    while IFS= read -r -d '' path; do
        plugins+=( "$path" )
    done < <(find "$root" -type f -path '*/dino/plugins/google-webrtc.so' -print0)
    while IFS= read -r -d '' path; do
        wrappers+=( "$path" )
    done < <(find "$root" -type f -path '*/lib/dinox/libdinox-google-webrtc.so' -print0)
    while IFS= read -r -d '' path; do
        workers+=( "$path" )
    done < <(find "$root" -type f -path '*/lib/dinox/dinox-webrtc-worker' -print0)

    if [ "${#plugins[@]}" -ne 1 ]; then
        printf 'google-webrtc.so: genau ein Paket-Plugin erwartet, gefunden: %s\n' "${#plugins[@]}"
        issues=1
    fi
    if [ "${#wrappers[@]}" -ne 1 ]; then
        printf 'libdinox-google-webrtc.so: genau ein privater Wrapper erwartet, gefunden: %s\n' "${#wrappers[@]}"
        issues=1
    fi
    if [ "${#workers[@]}" -ne 1 ]; then
        printf 'dinox-webrtc-worker: genau ein privater Worker erwartet, gefunden: %s\n' "${#workers[@]}"
        issues=1
    fi
    if [ "${#plugins[@]}" -ne 1 ] || [ "${#wrappers[@]}" -ne 1 ] \
            || [ "${#workers[@]}" -ne 1 ]; then
        return "$issues"
    fi

    plugin="${plugins[0]}"
    wrapper="${wrappers[0]}"
    worker="${workers[0]}"
    plugin_libdir="$(dirname "$(dirname "$(dirname "$plugin")")")"
    for path in "$plugin" "$wrapper" "$worker"; do
        relative="${path#"$root"/}"
        if ! LC_ALL=C "$readelf_cmd" -h "$path" >/dev/null 2>&1; then
            printf '%s: kein lesbares ELF\n' "$relative"
            issues=1
        fi
    done
    if [ ! -x "$worker" ]; then
        printf '%s: Worker ist nicht ausführbar\n' "${worker#"$root"/}"
        issues=1
    fi

    needed="$(elf_dynamic_value "$readelf_cmd" NEEDED "$plugin")"
    if ! grep -Fxq 'libdinox-google-webrtc.so' <<< "$needed"; then
        printf '%s: DT_NEEDED libdinox-google-webrtc.so fehlt\n' "${plugin#"$root"/}"
        issues=1
    fi
    if ! grep -Fxq 'libdino.so.0' <<< "$needed"; then
        printf '%s: DT_NEEDED libdino.so.0 fehlt\n' "${plugin#"$root"/}"
        issues=1
    fi
    if [ ! -e "$plugin_libdir/libdino.so.0" ]; then
        printf '%s: Paketbibliothek libdino.so.0 fehlt\n' \
            "${plugin_libdir#"$root"/}/libdino.so.0"
        issues=1
    fi
    if ! elf_origin_resolves_to_directory "$plugin" "$plugin_libdir"; then
        printf '%s: relativer $ORIGIN-Pfad löst den Paket-libdir %s nicht auf\n' \
            "${plugin#"$root"/}" "${plugin_libdir#"$root"/}"
        issues=1
    fi
    if ! elf_origin_resolves_to_directory "$plugin" "$(dirname "$wrapper")"; then
        printf '%s: relativer $ORIGIN-Pfad löst den privaten Wrapper-Pfad %s nicht auf\n' \
            "${plugin#"$root"/}" "${wrapper#"$root"/}"
        issues=1
    fi

    needed="$(elf_dynamic_value "$readelf_cmd" NEEDED "$wrapper")"
    for relative in libavcodec-dinox-hw.so.62 libavutil-dinox-hw.so.60; do
        if ! grep -Fxq "$relative" <<< "$needed"; then
            printf '%s: DT_NEEDED %s fehlt\n' "${wrapper#"$root"/}" "$relative"
            issues=1
        fi
        if [ ! -f "$(dirname "$wrapper")/$relative" ]; then
            printf '%s: private gleichgeordnete Bibliothek fehlt\n' \
                "$(dirname "${wrapper#"$root"/}")/$relative"
            issues=1
        fi
    done
    if ! elf_origin_resolves_to_directory "$wrapper" "$(dirname "$wrapper")"; then
        printf '%s: DT_RUNPATH/DT_RPATH enthält kein gleichgeordnetes $ORIGIN\n' \
            "${wrapper#"$root"/}"
        issues=1
    fi

    needed="$(elf_dynamic_value "$readelf_cmd" NEEDED "$worker")"
    if ! grep -Fxq 'libdinox-google-webrtc.so' <<< "$needed"; then
        printf '%s: DT_NEEDED libdinox-google-webrtc.so fehlt\n' "${worker#"$root"/}"
        issues=1
    fi
    if ! elf_origin_resolves_to_directory "$worker" "$(dirname "$wrapper")"; then
        printf '%s: DT_RUNPATH/DT_RPATH enthält keinen relativen Wrapper-Pfad\n' \
            "${worker#"$root"/}"
        issues=1
    fi

    return "$issues"
}

check_google_webrtc_runtime_paths() {
    local root="$1" label="$2"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local output rc=0

    if ! command -v "$readelf_cmd" >/dev/null 2>&1; then
        row_fail "$label nicht geprüft; readelf fehlt"
        return
    fi
    output="$(google_webrtc_runtime_path_issues "$root")" || rc=$?
    if [ "$rc" -eq 0 ]; then
        row_ok "$label (DT_NEEDED über paketrelative \$ORIGIN-Pfade)"
    else
        row_fail "$label nicht paketrelativ auflösbar"
        sed 's/^/    /' <<< "$output"
    fi
}

check_vision_runtime_bundle() {
    local base="$1" label="$2" output
    if output="$(python3 "$SCRIPT_DIR/check-vision-runtime.py" --base "$base" --platform linux \
            --readelf "${DINOX_READELF:-readelf}" 2>&1)"; then
        row_ok "$label (Worker, feste Modelle, Manifest und Original-Lizenzen)"
    else
        row_fail "$label unvollständig oder ungültig"
        sed 's/^/    /' <<< "$output"
    fi
}

elf_packaged_candidate_is_valid() {
    local root="$1" candidate="$2"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local resolved

    [ -e "$candidate" ] || return 1
    resolved="$(readlink -f -- "$candidate" 2>/dev/null || true)"
    case "$resolved" in
        "$root"/*) ;;
        *) return 1 ;;
    esac
    LC_ALL=C "$readelf_cmd" -h "$resolved" >/dev/null 2>&1
}

elf_package_search_directories() {
    local root="$1" profile="$2" path="$3"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local origin_directory runtime_path_list runtime_path suffix directory base relative
    local -a runtime_paths=()

    origin_directory="$(readlink -f "$(dirname "$path")")"
    relative="${path#"$root"/}"
    {
        # DT_RUNPATH/DT_RPATH is object-specific. Only package-relative
        # $ORIGIN entries are accepted; absolute entries fail the separate
        # RPATH gate and must not make this closure check pass accidentally.
        runtime_path_list="$({
            elf_dynamic_value "$readelf_cmd" RUNPATH "$path"
            elf_dynamic_value "$readelf_cmd" RPATH "$path"
        })"
        while IFS= read -r runtime_path_list; do
            [ -n "$runtime_path_list" ] || continue
            IFS=':' read -r -a runtime_paths <<< "$runtime_path_list"
            for runtime_path in "${runtime_paths[@]}"; do
                runtime_path="${runtime_path//'${ORIGIN}'/'$ORIGIN'}"
                case "$runtime_path" in
                    '$ORIGIN')
                        suffix=""
                        ;;
                    '$ORIGIN/'*)
                        suffix="${runtime_path#\$ORIGIN/}"
                        ;;
                    *)
                        continue
                        ;;
                esac
                readlink -m "$origin_directory/${suffix:-.}"
            done
        done <<< "$runtime_path_list"

        case "$profile" in
            appdir)
                # AppRun exports exactly these package roots before DinoX and
                # all child processes are started. The AppDir gate separately
                # verifies that the launcher still contains this model.
                for directory in "$root/usr/lib/dinox" "$root/usr/lib"; do
                    [ -d "$directory" ] && printf '%s\n' "$directory"
                done
                base="$root/usr/lib"
                if [ -d "$base" ]; then
                    find "$base" -mindepth 1 -maxdepth 1 -type d \
                        -name '*-linux-gnu' -print 2>/dev/null || true
                fi
                ;;
            deb)
                # /usr/bin/dinox exports the private directory. Standard
                # loader directories remain package paths after installation.
                [ -d "$root/usr/lib/dinox" ] && printf '%s\n' "$root/usr/lib/dinox"
                for directory in \
                        "$root/lib" "$root/lib64" \
                        "$root/usr/lib" "$root/usr/lib64"; do
                    [ -d "$directory" ] && printf '%s\n' "$directory"
                done
                for base in "$root/lib" "$root/usr/lib"; do
                    [ -d "$base" ] || continue
                    find "$base" -mindepth 1 -maxdepth 1 -type d \
                        -name '*-linux-gnu' -print 2>/dev/null || true
                done
                case "$relative" in
                    usr/lib/dinox/tor.real|usr/lib/dinox/tor-libs/*)
                        # The packaged /usr/lib/dinox/tor wrapper prepends this
                        # directory before executing tor.real; its dependent
                        # libevent objects inherit the same loader environment.
                        [ -d "$root/usr/lib/dinox/tor-libs" ] \
                            && printf '%s\n' "$root/usr/lib/dinox/tor-libs"
                        ;;
                esac
                ;;
        esac
    } | awk 'NF && !seen[$0]++'
}

elf_needed_resolves_in_package() {
    local root="$1" profile="$2" path="$3" needed="$4"
    local directory

    case "$needed" in
        */*) return 1 ;;
    esac
    while IFS= read -r directory; do
        [ -n "$directory" ] || continue
        if elf_packaged_candidate_is_valid "$root" "$directory/$needed"; then
            return 0
        fi
    done < <(elf_package_search_directories "$root" "$profile" "$path")
    return 1
}

release_forbidden_artifact_issues() {
    local requested_root="$1"
    local root
    root="$(readlink -f "$requested_root")"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local path relative lowered
    local issues=0

    while IFS= read -r -d '' path; do
        relative="${path#"$root"/}"
        lowered="$(printf '%s' "$relative" | tr '[:upper:]' '[:lower:]')"

        case "$relative" in
            */dino/plugins/rtp.so)
                printf '%s: altes GStreamer-RTP-Plugin ist in einem Release-Artefakt verboten\n' \
                    "$relative"
                issues=1
                ;;
        esac

        if [[ "$lowered" == *webrtc* ]] \
                && { [[ "$lowered" == *test-oracle* ]] \
                    || [[ "$lowered" == *test_oracle* ]] \
                    || [[ "$lowered" == *smoke* ]]; }; then
            printf '%s: WebRTC-Testartefakt ist in einem Release-Artefakt verboten\n' \
                "$relative"
            issues=1
        fi

        [ -L "$path" ] && continue
        if LC_ALL=C "$readelf_cmd" -h "$path" >/dev/null 2>&1 \
                && grep -aF \
                    -e 'DINOX_WEBRTC_IN_PROCESS_TEST_ORACLE' \
                    -e 'DINOX_WEBRTC_ENABLE_IN_PROCESS_TEST_ORACLE' \
                    "$path" >/dev/null 2>&1; then
            printf '%s: WebRTC-Test-Oracle-Marker ist in einem Release-ELF verboten\n' \
                "$relative"
            issues=1
        fi
    done < <(find "$root" \( -type f -o -type l \) -print0)

    return "$issues"
}

check_release_forbidden_artifacts() {
    local root="$1" label="$2"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local output rc=0

    if ! command -v "$readelf_cmd" >/dev/null 2>&1; then
        row_fail "$label nicht geprüft; readelf fehlt"
        return
    fi
    output="$(release_forbidden_artifact_issues "$root")" || rc=$?
    if [ "$rc" -eq 0 ]; then
        row_ok "$label (kein RTP-/Oracle-/WebRTC-Testmaterial)"
    else
        row_fail "$label enthält release-verbotene Test-/Altartefakte"
        sed 's/^/    /' <<< "$output"
    fi
}

elf_closure_issues() {
    local requested_root="$1" profile="$2"
    local root
    root="$(readlink -f "$requested_root")"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local path needed relative
    local -a elf_files=()
    local unresolved=0

    while IFS= read -r -d '' path; do
        if LC_ALL=C "$readelf_cmd" -h "$path" >/dev/null 2>&1; then
            elf_files+=( "$path" )
        fi
    done < <(find "$root" -type f -print0)

    for path in "${elf_files[@]}"; do
        while IFS= read -r needed; do
            [ -n "$needed" ] || continue
            if elf_host_abi_allowed "$profile" "$needed" \
                    || elf_needed_resolves_in_package "$root" "$profile" "$path" "$needed"; then
                continue
            fi
            relative="${path#"$root"/}"
            printf '%s -> %s\n' "$relative" "$needed"
            unresolved=1
        done < <(elf_dynamic_value "$readelf_cmd" NEEDED "$path")
    done
    return "$unresolved"
}

check_all_elf_closure() {
    local root="$1" profile="$2" label="$3"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local output rc=0

    if ! command -v "$readelf_cmd" >/dev/null 2>&1; then
        row_fail "$label nicht geprüft; readelf fehlt"
        return
    fi
    output="$(elf_closure_issues "$root" "$profile")" || rc=$?
    if [ "$rc" -eq 0 ]; then
        row_ok "$label (statisch, keine Paket-Binärdatei ausgeführt)"
    else
        row_fail "$label ungelöste DT_NEEDED-Einträge"
        sed 's/^/    /' <<< "$output"
    fi
}

run_ffmpeg_capability_probe() {
    local ffmpeg="$1" probe="$2" lib_path="${3:-}"
    local effective_lib_path="$lib_path"
    local -a command=( "$ffmpeg" -hide_banner "$probe" )
    if have_cmd timeout; then
        command=( timeout --kill-after=5s 15s "${command[@]}" )
    fi
    if [ -n "${LD_LIBRARY_PATH:-}" ]; then
        effective_lib_path="${effective_lib_path:+$effective_lib_path:}$LD_LIBRARY_PATH"
    fi
    LC_ALL=C LD_LIBRARY_PATH="$effective_lib_path" \
        "${command[@]}" 2>&1
}

run_ffmpeg_process() {
    local ffmpeg="$1" lib_path="$2"
    shift 2
    local effective_lib_path="$lib_path"
    local -a command=( "$ffmpeg" "$@" )
    if have_cmd timeout; then
        command=( timeout --kill-after=5s 20s "${command[@]}" )
    fi
    if [ -n "${LD_LIBRARY_PATH:-}" ]; then
        effective_lib_path="${effective_lib_path:+$effective_lib_path:}$LD_LIBRARY_PATH"
    fi
    LC_ALL=C LD_LIBRARY_PATH="$effective_lib_path" "${command[@]}"
}

ffmpeg_capability_present() {
    local output="$1" capability="$2"
    awk -v capability="$capability" '$2 == capability { found = 1 } END { exit(found ? 0 : 1) }' \
        <<< "$output"
}

gnupg_version_from_output() {
    sed -nE '1s/^.*\(GnuPG\) ([0-9]+(\.[0-9]+)+).*$/\1/p'
}

diagnose_ffmpeg_writer_smoke() {
    local ffmpeg="$1" lib_path="$2" encoder="$3" label_prefix="$4"
    local tmp_dir audio_file video_file av_file
    local video_ok=0 audio_ok=0
    local -a video_encoder_args=( -c:v "$encoder" )

    have_cmd dd || {
        row_fail "$label_prefix Writer-Smokes nicht möglich; dd fehlt"
        return
    }
    if [ "$encoder" = "libx264" ]; then
        video_encoder_args+=(
            -preset veryfast
            -tune zerolatency
            -profile:v baseline
        )
    fi

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dinox-recorder-matrix.XXXXXX")"
    audio_file="$tmp_dir/audio.m4a"
    video_file="$tmp_dir/video.mp4"
    av_file="$tmp_dir/audio-video.mp4"

    if dd if=/dev/zero bs=24000 count=1 2>/dev/null \
            | run_ffmpeg_process "$ffmpeg" "$lib_path" \
                -hide_banner -loglevel error -y \
                -f s16le -ar 48000 -ac 1 -i pipe:0 -vn \
                -c:a aac -b:a 96000 -movflags +faststart -f ipod "$audio_file" \
            && [ -s "$audio_file" ]; then
        row_ok "$label_prefix echter AAC/M4A-Writer"
        audio_ok=1
    else
        row_fail "$label_prefix echter AAC/M4A-Writer fehlgeschlagen"
    fi

    if dd if=/dev/zero bs=49152 count=1 2>/dev/null \
            | run_ffmpeg_process "$ffmpeg" "$lib_path" \
                -hide_banner -loglevel error -y \
                -f rawvideo -pix_fmt bgra -s:v 64x64 -r 5 -i pipe:0 -an \
                "${video_encoder_args[@]}" \
                -b:v 300000 -maxrate 300000 -bufsize 600000 \
                -pix_fmt yuv420p -movflags +faststart -f mp4 "$video_file" \
            && [ -s "$video_file" ]; then
        row_ok "$label_prefix echter H.264/MP4-Writer ($encoder)"
        video_ok=1
    else
        row_fail "$label_prefix echter H.264/MP4-Writer fehlgeschlagen ($encoder)"
    fi

    if [ "$audio_ok" -eq 1 ] && [ "$video_ok" -eq 1 ] \
            && run_ffmpeg_process "$ffmpeg" "$lib_path" \
                -hide_banner -loglevel error -y \
                -i "$video_file" -i "$audio_file" \
                -map 0:v:0 -map 1:a:0 -c copy -shortest \
                -movflags +faststart -f mp4 "$av_file" </dev/null \
            && [ -s "$av_file" ]; then
        row_ok "$label_prefix echtes Audio/Video-Copy-Muxing"
    else
        row_fail "$label_prefix echtes Audio/Video-Copy-Muxing fehlgeschlagen"
    fi

    rm -rf "$tmp_dir"
}

check_private_recorder_codec_boundary() {
    local ffmpeg="$1" label="$2"
    local readelf_cmd="${DINOX_READELF:-readelf}"
    local needed

    if ! command -v "$readelf_cmd" >/dev/null 2>&1; then
        row_fail "$label Codec-Linkage nicht geprüft; readelf fehlt"
        return
    fi
    needed="$(LC_ALL=C "$readelf_cmd" -d --wide "$ffmpeg" 2>/dev/null \
        | sed -nE 's/.*\(NEEDED\).*\[([^]]+)\].*/\1/p')"
    if grep -Eq '^lib(avcodec|avdevice|avfilter|avformat|avutil|postproc|swresample|swscale|x264)\.so' <<< "$needed"; then
        row_fail "$label bindet dynamische FFmpeg-/x264-Codec-SONAMEs ein"
    else
        row_ok "$label FFmpeg/x264 statisch, keine Codec-SONAME-Kollision"
    fi
}

diagnose_linux_ffmpeg_recorder() {
    local ffmpeg="$1" lib_path="${2:-}" label_prefix="${3:-System ffmpeg}"
    local required_encoder="${4:-either}"
    local encoders muxers encoder=""

    section "Linux Nachrichten-Recorder (Google/libwebrtc + ffmpeg-CLI)"
    if [ -z "$ffmpeg" ] || [ ! -x "$ffmpeg" ]; then
        row_fail "$label_prefix fehlt"
        return
    fi
    row_ok "$label_prefix"

    if ! encoders="$(run_ffmpeg_capability_probe "$ffmpeg" -encoders "$lib_path")"; then
        row_fail "$label_prefix Encoder-Liste nicht lesbar"
        return
    fi
    if ! muxers="$(run_ffmpeg_capability_probe "$ffmpeg" -muxers "$lib_path")"; then
        row_fail "$label_prefix Muxer-Liste nicht lesbar"
        return
    fi

    ffmpeg_capability_present "$encoders" aac \
        && row_ok "ffmpeg AAC-Encoder für M4A" || row_fail "ffmpeg AAC-Encoder für M4A fehlt"
    ffmpeg_capability_present "$muxers" ipod \
        && row_ok "ffmpeg ipod/M4A-Muxer" || row_fail "ffmpeg ipod/M4A-Muxer fehlt"
    ffmpeg_capability_present "$muxers" mp4 \
        && row_ok "ffmpeg MP4-Muxer" || row_fail "ffmpeg MP4-Muxer fehlt"
    case "$required_encoder" in
        libx264)
            if ffmpeg_capability_present "$encoders" libx264; then
                encoder=libx264
                row_ok "ffmpeg privater libx264 H.264-Encoder"
            else
                row_fail "ffmpeg privater libx264 H.264-Encoder fehlt"
            fi
            ;;
        either)
            if ffmpeg_capability_present "$encoders" libx264; then
                encoder=libx264
                row_ok "ffmpeg Software-H.264-Encoder (libx264)"
            elif ffmpeg_capability_present "$encoders" libopenh264; then
                encoder=libopenh264
                row_ok "ffmpeg Software-H.264-Encoder (libopenh264)"
            else
                row_fail "ffmpeg Software-H.264-Encoder fehlt (libx264/libopenh264)"
            fi
            ;;
        *)
            row_fail "interner ffmpeg Encoder-Modus ungültig: $required_encoder"
            ;;
    esac

    if [ -n "$encoder" ]; then
        diagnose_ffmpeg_writer_smoke "$ffmpeg" "$lib_path" "$encoder" "$label_prefix"
    fi
}

google_libwebrtc_notice_files() {
    cat <<'EOF'
LICENSE
LICENSE.md
PATENTS
manifest.json
FFMPEG-LICENSE
LIBVA-LICENSE
FFMPEG-VP8-VAAPI.json
NVIDIA-CODEC-HEADERS-LICENSE
WEBRTC-CODECS.json
WEBRTC-GN-ARGS.gn
EOF
}

packaged_gstreamer_plugins() {
    cat <<'EOF'
libgstcoreelements.so|GStreamer Core Elements Plugin|GStreamer Core Elements
libgstapp.so|GStreamer App Plugin|GStreamer App
libgsttypefindfunctions.so|GStreamer Typefind Plugin|GStreamer Typefind
libgstplayback.so|GStreamer Playback Plugin|GStreamer Playback
libgstaudioparsers.so|GStreamer Audio Parsers Plugin|GStreamer Audio Parsers
libgstaudioconvert.so|GStreamer Audio Convert Plugin|GStreamer Audio Convert
libgstaudioresample.so|GStreamer Audio Resample Plugin|GStreamer Audio Resample
libgstlevel.so|GStreamer Level Plugin|GStreamer Level
libgstvolume.so|GStreamer Volume Plugin|GStreamer Volume
libgstopus.so|GStreamer Opus Plugin|GStreamer Opus
libgstvorbis.so|GStreamer Vorbis Plugin|GStreamer Vorbis
libgstvpx.so|GStreamer VPX Plugin|GStreamer VPX
libgstlibav.so|GStreamer libav Plugin|GStreamer libav
libgstvideoconvertscale.so|GStreamer Video Convert Scale Plugin|GStreamer Video Convert Scale
libgstvideoparsersbad.so|GStreamer Video Parsers Plugin|GStreamer Video Parsers
libgstisomp4.so|GStreamer MP4 Plugin|GStreamer MP4
libgstmatroska.so|GStreamer Matroska/WebM Plugin|GStreamer Matroska/WebM
libgstgio.so|GStreamer GIO Plugin|GStreamer GIO
libgstogg.so|GStreamer Ogg Plugin|GStreamer Ogg
libgstwavparse.so|GStreamer WAV Parser Plugin|GStreamer WAV Parser
libgstautodetect.so|GStreamer Auto Detect Plugin|GStreamer Auto Detect
libgstpulseaudio.so|GStreamer PulseAudio Plugin|GStreamer PulseAudio
libgstalsa.so|GStreamer ALSA Plugin|GStreamer ALSA
libgstpipewire.so|GStreamer PipeWire Plugin|GStreamer PipeWire
EOF
}

packaged_gstreamer_plugin_exists() {
    local expected="$1"
    local plugin app_label deb_label

    while IFS='|' read -r plugin app_label deb_label; do
        [ "$plugin" = "$expected" ] && return 0
    done < <(packaged_gstreamer_plugins)
    return 1
}

check_appdir_gio_tls() {
    local appdir="$1"
    local module_dir="$appdir/usr/lib/gio/modules"

    # These modules are loaded at runtime and cannot be discovered by an ELF
    # DT_NEEDED closure check. Keep this CI check static: no GTK/media startup.
    check_nonempty_file "$module_dir/libgiognutls.so" "AppDir GIO TLS-Modul"
    check_nonempty_file "$module_dir/giomodule.cache" "AppDir GIO Modulcache"
    if [ -s "$module_dir/giomodule.cache" ] && awk '
        $1 == "libgiognutls.so:" {
            count = split($2, extensions, ",")
            for (i = 1; i <= count; i++) {
                if (extensions[i] == "gio-tls-backend") found = 1
            }
        }
        END { exit(!found) }
    ' "$module_dir/giomodule.cache"; then
        row_ok "AppDir GIO TLS-Backend registriert"
    else
        row_fail "AppDir GIO TLS-Backend fehlt im Modulcache"
    fi
    check_file_contains "$appdir/AppRun" \
        'export GIO_MODULE_DIR="${APPDIR}/usr/lib/gio/modules"' \
        "AppRun GIO Modulpfad"
    check_file_contains "$appdir/AppRun" 'unset GIO_EXTRA_MODULES' "AppRun ohne externe GIO-Module"
}

assert_appdir_gio_tls_gate() (
    local root output
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' EXIT
    : > "$root/AppRun"

    output="$(fail_count=0; check_appdir_gio_tls "$root"; echo "FAIL_COUNT=$fail_count")"
    grep -qF 'FAIL_COUNT=5' <<< "$output" || return 1

    mkdir -p "$root/usr/lib/gio/modules"
    printf 'test module\n' > "$root/usr/lib/gio/modules/libgiognutls.so"
    printf '%s\n' 'export GIO_MODULE_DIR="${APPDIR}/usr/lib/gio/modules"' 'unset GIO_EXTRA_MODULES' > "$root/AppRun"
    printf 'libgiognutls.so: gio-dtls-backend,gio-tls-backend\n' > "$root/usr/lib/gio/modules/giomodule.cache"
    output="$(fail_count=0; check_appdir_gio_tls "$root"; echo "FAIL_COUNT=$fail_count")"
    grep -qF 'FAIL_COUNT=0' <<< "$output" || return 1

    # A cache for another module, or DTLS alone, must not satisfy TLS support.
    printf 'libgiognutls.so: gio-dtls-backend\nother.so: gio-tls-backend\n' > "$root/usr/lib/gio/modules/giomodule.cache"
    output="$(fail_count=0; check_appdir_gio_tls "$root"; echo "FAIL_COUNT=$fail_count")"
    grep -qF 'FAIL_COUNT=1' <<< "$output" || return 1

    printf 'libgiognutls.so: gio-tls-backend\n' > "$root/usr/lib/gio/modules/giomodule.cache"
    : > "$root/usr/lib/gio/modules/libgiognutls.so"
    output="$(fail_count=0; check_appdir_gio_tls "$root"; echo "FAIL_COUNT=$fail_count")"
    grep -qF 'FAIL_COUNT=1' <<< "$output" || return 1

    # The former EXTRA_MODULES-only setup still loads incompatible host modules.
    printf 'test module\n' > "$root/usr/lib/gio/modules/libgiognutls.so"
    printf '%s\n' 'export GIO_EXTRA_MODULES="${APPDIR}/usr/lib/gio/modules"' > "$root/AppRun"
    output="$(fail_count=0; check_appdir_gio_tls "$root"; echo "FAIL_COUNT=$fail_count")"
    grep -qF 'FAIL_COUNT=2' <<< "$output" || return 1
)

check_appdir_gtk_modules() {
    local appdir="$1"
    check_nonempty_file "$appdir/usr/lib/gtk-4.0/4.0.0/media/libmedia-gstreamer.so" "AppDir GTK Medienmodul"
    check_file_contains "$appdir/AppRun" 'export GTK_EXE_PREFIX="${APPDIR}/usr"' "AppRun GTK Modulbasis"
    check_file_contains "$appdir/AppRun" 'export GTK_PATH="${APPDIR}/usr/lib/gtk-4.0"' "AppRun ohne externe GTK-Module"
}

assert_appdir_gtk_modules_gate() (
    local root output
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' EXIT
    : > "$root/AppRun"
    output="$(fail_count=0; check_appdir_gtk_modules "$root"; echo "FAIL_COUNT=$fail_count")"
    grep -qF 'FAIL_COUNT=3' <<< "$output" || return 1
    mkdir -p "$root/usr/lib/gtk-4.0/4.0.0/media"
    printf 'test module\n' > "$root/usr/lib/gtk-4.0/4.0.0/media/libmedia-gstreamer.so"
    printf '%s\n' 'export GTK_EXE_PREFIX="${APPDIR}/usr"' \
        'export GTK_PATH="${APPDIR}/usr/lib/gtk-4.0"' > "$root/AppRun"
    output="$(fail_count=0; check_appdir_gtk_modules "$root"; echo "FAIL_COUNT=$fail_count")"
    grep -qF 'FAIL_COUNT=0' <<< "$output" || return 1
    # Bundling the module without redirecting GTK's compiled-in path is not enough.
    : > "$root/AppRun"
    output="$(fail_count=0; check_appdir_gtk_modules "$root"; echo "FAIL_COUNT=$fail_count")"
    grep -qF 'FAIL_COUNT=2' <<< "$output" || return 1
)

check_appdir_gstreamer_plugins() {
    local appdir="$1"
    local plugin app_label deb_label

    while IFS='|' read -r plugin app_label deb_label; do
        check_file "$appdir/usr/lib/gstreamer-1.0/$plugin" "$app_label"
    done < <(packaged_gstreamer_plugins)
}

appdir_auxiliary_module_files() {
    printf '%s\n' \
        usr/lib/gio/modules/{libdconfsettings,libgiolibproxy,libgiognomeproxy,libgvfsdbus}.so \
        usr/lib/lib{softokn3,freebl3,freeblpriv3,nssckbi}.so \
        usr/lib/dinox/libcanberra.so.0 \
        usr/lib/dinox/canberra/libcanberra-{alsa,pulse,multi,null}.so \
        usr/lib/libheif/plugins/libheif-{dav1d,libde265}.so \
        usr/lib/ossl-modules/legacy.so \
        usr/lib/engines-3/{afalg,loader_attic,padlock}.so \
        usr/share/glib-2.0/schemas/gschemas.compiled \
        usr/share/glib-2.0/schemas/org.gnome.system.proxy.gschema.xml \
        usr/share/glib-2.0/schemas/org.gnome.desktop.enums.xml \
        usr/share/sounds/freedesktop/index.theme \
        usr/share/sounds/freedesktop/stereo/{message-new-instant,phone-incoming-call,phone-outgoing-calling}.oga
}

check_appdir_auxiliary_modules() {
    local appdir="$1" relative variable directory
    while IFS= read -r relative; do
        check_nonempty_file "$appdir/$relative" "AppDir $relative"
    done < <(appdir_auxiliary_module_files)
    if grep -aqF 'DINOX_CANBERRA_MODULE_DIR' "$appdir/usr/lib/dinox/libcanberra.so.0" 2>/dev/null; then
        row_ok "AppDir libcanberra mit relocatable Modulpfad"
    else
        row_fail "AppDir libcanberra verwendet weiterhin fest eingebauten Modulpfad"
    fi
    while IFS='|' read -r variable directory; do
        check_file_contains "$appdir/AppRun" "export $variable=\"\${APPDIR}/usr/lib/$directory\"" "AppRun $variable"
    done <<'MODULE_PATHS'
LIBHEIF_PLUGIN_PATH|libheif/plugins
DINOX_CANBERRA_MODULE_DIR|dinox/canberra
OPENSSL_MODULES|ossl-modules
OPENSSL_ENGINES|engines-3
MODULE_PATHS
}

assert_appdir_auxiliary_modules_gate() (
    local root relative output
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' EXIT
    while IFS= read -r relative; do
        mkdir -p "$(dirname "$root/$relative")"
        printf 'fixture\n' > "$root/$relative"
    done < <(appdir_auxiliary_module_files)
    printf 'DINOX_CANBERRA_MODULE_DIR\n' >> "$root/usr/lib/dinox/libcanberra.so.0"
    cat > "$root/AppRun" <<'FIXTURE'
export LIBHEIF_PLUGIN_PATH="${APPDIR}/usr/lib/libheif/plugins"
export DINOX_CANBERRA_MODULE_DIR="${APPDIR}/usr/lib/dinox/canberra"
export OPENSSL_MODULES="${APPDIR}/usr/lib/ossl-modules"
export OPENSSL_ENGINES="${APPDIR}/usr/lib/engines-3"
FIXTURE
    output="$(fail_count=0; check_appdir_auxiliary_modules "$root"; echo "FAIL_COUNT=$fail_count")"
    grep -qF 'FAIL_COUNT=0' <<< "$output" || return 1
    rm "$root/usr/lib/dinox/canberra/libcanberra-pulse.so"
    output="$(fail_count=0; check_appdir_auxiliary_modules "$root"; echo "FAIL_COUNT=$fail_count")"
    grep -qF 'FAIL_COUNT=1' <<< "$output" || return 1
    printf 'unpatched library\n' > "$root/usr/lib/dinox/libcanberra.so.0"
    output="$(fail_count=0; check_appdir_auxiliary_modules "$root"; echo "FAIL_COUNT=$fail_count")"
    grep -qF 'FAIL_COUNT=2' <<< "$output" || return 1
    : > "$root/AppRun"
    output="$(fail_count=0; check_appdir_auxiliary_modules "$root"; echo "FAIL_COUNT=$fail_count")"
    grep -qF 'FAIL_COUNT=6' <<< "$output" || return 1
)

output_has_appdir_gstreamer_plugin_failures() {
    local output="$1"
    local plugin app_label deb_label

    while IFS='|' read -r plugin app_label deb_label; do
        grep -qF "[FAIL] $app_label fehlt" <<< "$output" || return 1
    done < <(packaged_gstreamer_plugins)
}

gst_check() {
    local element="$1"
    if [ "$GST_CHECK_MODE" = "static" ]; then
        local plugin
        plugin="$(gst_plugin_for_element "$element")"
        [ -n "$plugin" ] && [ -f "$GST_STATIC_PLUGIN_DIR/$plugin" ]
        return $?
    fi

    run_gst_inspect "$element"
}

gst_plugin_for_element() {
    case "$1" in
        playbin|uridecodebin|decodebin) echo "libgstplayback.so" ;;
        typefind) echo "libgsttypefindfunctions.so" ;;
        queue|filesrc|fakesink|capsfilter) echo "libgstcoreelements.so" ;;
        appsink) echo "libgstapp.so" ;;
        audioconvert) echo "libgstaudioconvert.so" ;;
        audioresample) echo "libgstaudioresample.so" ;;
        level) echo "libgstlevel.so" ;;
        volume) echo "libgstvolume.so" ;;
        avdec_aac|avdec_h264) echo "libgstlibav.so" ;;
        aacparse) echo "libgstaudioparsers.so" ;;
        qtdemux) echo "libgstisomp4.so" ;;
        videoconvert) echo "libgstvideoconvertscale.so" ;;
        openh264dec) echo "libgstopenh264.so" ;;
        h264parse) echo "libgstvideoparsersbad.so" ;;
        matroskademux) echo "libgstmatroska.so" ;;
        opusdec) echo "libgstopus.so" ;;
        vorbisdec) echo "libgstvorbis.so" ;;
        vp8dec|vp9dec) echo "libgstvpx.so" ;;
        giostreamsrc) echo "libgstgio.so" ;;
        oggdemux) echo "libgstogg.so" ;;
        wavparse) echo "libgstwavparse.so" ;;
        autoaudiosink) echo "libgstautodetect.so" ;;
        pulsesink) echo "libgstpulseaudio.so" ;;
        alsasink) echo "libgstalsa.so" ;;
        pipewiresink) echo "libgstpipewire.so" ;;
        *) return 1 ;;
    esac
}

check_gst_element() {
    local element="$1" label="${2:-$1}" required="${3:-true}"
    local rc=0
    gst_check "$element" || rc=$?
    if [ "$rc" -eq 0 ]; then
        row_ok "$label"
    elif [ "$rc" -eq 124 ]; then
        if [ "$required" = "true" ]; then
            row_fail "$label Timeout nach ${GST_INSPECT_TIMEOUT}s"
        else
            row_warn "$label Timeout nach ${GST_INSPECT_TIMEOUT}s"
        fi
    elif [ "$required" = "true" ]; then
        row_fail "$label fehlt"
    else
        row_warn "$label fehlt"
    fi
}

check_gst_any() {
    local label="$1"
    shift
    local found=()
    local missing=()
    local timed_out=()
    local element
    local rc
    for element in "$@"; do
        rc=0
        gst_check "$element" || rc=$?
        if [ "$rc" -eq 0 ]; then
            found+=( "$element" )
        elif [ "$rc" -eq 124 ]; then
            timed_out+=( "$element" )
        else
            missing+=( "$element" )
        fi
    done

    if [ "${#found[@]}" -gt 0 ]; then
        row_ok "$label: ${found[*]}"
        if [ "${#missing[@]}" -gt 0 ]; then
            row_warn "$label Fallbacks fehlen: ${missing[*]}"
        fi
        if [ "${#timed_out[@]}" -gt 0 ]; then
            row_warn "$label Fallbacks Timeout nach ${GST_INSPECT_TIMEOUT}s: ${timed_out[*]}"
        fi
    elif [ "${#timed_out[@]}" -gt 0 ]; then
        row_fail "$label: Timeout nach ${GST_INSPECT_TIMEOUT}s (${timed_out[*]})"
    else
        row_fail "$label: keiner vorhanden (${missing[*]})"
    fi
}

assert_self_test() {
    local label="$1"
    shift
    printf '  [RUN]  %s\n' "$label"
    if "$@"; then
        row_ok "$label"
    else
        row_fail "$label"
    fi
}

assert_plugin_mapping() {
    local element="$1" expected="$2"
    [ "$(gst_plugin_for_element "$element")" = "$expected" ]
}

assert_unknown_plugin_fails() {
    ! gst_plugin_for_element "__dinox_unknown_element__" >/dev/null
}

assert_ibus_alias_absence_gate() (
    local root alias_path
    root="$(mktemp -d)"
    trap 'rm -rf -- "$root"' EXIT
    mkdir -p "$root/path with spaces/ibus-compat"
    alias_path="$root/path with spaces/ibus-compat/libibus-1.0.so.5"
    touch "$alias_path.0.530"

    assert_absence_result() {
        local pattern="$1" expected_ok="$2" expected_fail="$3"
        ok_count=0
        fail_count=0
        check_glob_absent "$pattern" "IBus Fallback ohne SONAME-Alias" >/dev/null
        [ "$ok_count" -eq "$expected_ok" ] && [ "$fail_count" -eq "$expected_fail" ]
    }

    # The versioned payload is allowed; the exact SONAME alias is absent.
    assert_absence_result "$alias_path" 1 0 || return 1
    assert_absence_result "$root/path with spaces/ibus-compat/*.so.5" 1 0 || return 1
    touch "$alias_path"
    assert_absence_result "$alias_path" 0 1 || return 1
    assert_absence_result "$root/path with spaces/ibus-compat/*.so.5" 0 1 || return 1
    rm -- "$alias_path"
    ln -s "libibus-1.0.so.5.0.530" "$alias_path"
    assert_absence_result "$alias_path" 0 1 || return 1
    rm -- "$alias_path"
    ln -s "missing-library" "$alias_path"
    assert_absence_result "$alias_path" 0 1 || return 1
    assert_absence_result "$root/path with spaces/ibus-compat/*.so.5" 0 1 || return 1
)

assert_static_gst_check() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local old_mode="$GST_CHECK_MODE"
    local old_static_dir="$GST_STATIC_PLUGIN_DIR"
    local rc=0
    GST_CHECK_MODE="static"
    GST_STATIC_PLUGIN_DIR="$tmp_dir"

    touch "$tmp_dir/libgstplayback.so"
    if ! gst_check playbin; then
        rc=1
    else
        rm "$tmp_dir/libgstplayback.so"
        if gst_check playbin; then
            rc=1
        fi
    fi

    GST_CHECK_MODE="$old_mode"
    GST_STATIC_PLUGIN_DIR="$old_static_dir"
    rm -rf "$tmp_dir"
    return "$rc"
}

assert_static_gst_mappings_are_packaged() {
    local element plugin
    local elements=(
        playbin uridecodebin decodebin typefind queue filesrc fakesink capsfilter
        appsink audioconvert audioresample level volume aacparse avdec_aac
        videoconvert avdec_h264 h264parse qtdemux matroskademux
        opusdec vorbisdec vp8dec vp9dec giostreamsrc oggdemux wavparse
        autoaudiosink pulsesink alsasink pipewiresink
    )

    for element in "${elements[@]}"; do
        plugin="$(gst_plugin_for_element "$element")" || return 1
        packaged_gstreamer_plugin_exists "$plugin" || return 1
    done
}

assert_legacy_gst_call_and_recorder_mappings_absent() {
    local element
    local elements=(
        appsrc nicesrc nicesink rtpopuspay rtpopusdepay rtppcmapay
        rtppcmadepay rtppcmupay opusenc avenc_aac voaacenc mp4mux
        x264enc openh264enc autoaudiosrc autovideosrc pipewiresrc v4l2src
    )
    for element in "${elements[@]}"; do
        if gst_plugin_for_element "$element" >/dev/null 2>&1; then
            return 1
        fi
    done
}

assert_packaged_gstreamer_plugins_unique() {
    local plugin app_label deb_label
    local seen=""

    while IFS='|' read -r plugin app_label deb_label; do
        case "$seen" in
            *"|$plugin|"*) return 1 ;;
        esac
        seen="${seen}|${plugin}|"
    done < <(packaged_gstreamer_plugins)
}

assert_packaged_gstreamer_plugins_have_labels() {
    local line plugin app_label deb_label extra

    while IFS= read -r line; do
        IFS='|' read -r plugin app_label deb_label extra <<< "$line"
        [ -n "$plugin" ] || return 1
        [ -n "$app_label" ] || return 1
        [ -n "$deb_label" ] || return 1
        [ -z "${extra:-}" ] || return 1
    done < <(packaged_gstreamer_plugins)
}

assert_packaged_gstreamer_plugins_have_filenames() {
    local plugin app_label deb_label

    while IFS='|' read -r plugin app_label deb_label; do
        case "$plugin" in
            libgst*.so) ;;
            *) return 1 ;;
        esac
        case "$plugin" in
            */*) return 1 ;;
        esac
    done < <(packaged_gstreamer_plugins)
}

assert_packaged_gstreamer_plugin_labels_unique() {
    local plugin app_label deb_label
    local app_seen="" deb_seen=""

    while IFS='|' read -r plugin app_label deb_label; do
        case "$app_seen" in
            *"|$app_label|"*) return 1 ;;
        esac
        case "$deb_seen" in
            *"|$deb_label|"*) return 1 ;;
        esac
        app_seen="${app_seen}|${app_label}|"
        deb_seen="${deb_seen}|${deb_label}|"
    done < <(packaged_gstreamer_plugins)
}

assert_production_plugin_inventory_gate() {
    local root plugin elf_fixture

    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mkdir -p "$root/usr/lib/dino/plugins"
    elf_fixture="$(readlink -f "$BASH")"
    [ -s "$elf_fixture" ] || return 1

    while IFS= read -r plugin; do
        cp "$elf_fixture" "$root/usr/lib/dino/plugins/$plugin"
    done < <(production_plugin_names)

    production_plugin_inventory_issues "$root" >/dev/null || return 1

    mv "$root/usr/lib/dino/plugins/http-files.so" \
        "$root/usr/lib/dino/plugins/http-files.so.missing"
    if production_plugin_inventory_issues "$root" >/dev/null 2>&1; then
        return 1
    fi
    mv "$root/usr/lib/dino/plugins/http-files.so.missing" \
        "$root/usr/lib/dino/plugins/http-files.so"

    printf 'not an ELF plugin\n' > "$root/usr/lib/dino/plugins/openpgp.so"
    if production_plugin_inventory_issues "$root" >/dev/null 2>&1; then
        return 1
    fi

    rm -rf "$root"
    trap - RETURN
}

stage_translation_catalog_fixture() {
    local root="$1"
    local domain linguas_relative line language catalog

    while IFS='|' read -r domain linguas_relative; do
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            for language in $line; do
                catalog="$root/usr/share/locale/$language/LC_MESSAGES/$domain.mo"
                mkdir -p "$(dirname "$catalog")"
                printf 'fixture %s %s\n' "$domain" "$language" > "$catalog"
            done
        done < "$PROJECT_ROOT/$linguas_relative"
    done < <(translation_catalog_domains)
}

assert_translation_catalog_inventory_gate() {
    local root missing_catalog

    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    stage_translation_catalog_fixture "$root"

    translation_catalog_inventory_issues "$root" "$PROJECT_ROOT" >/dev/null \
        || return 1

    missing_catalog="$root/usr/share/locale/ru/LC_MESSAGES/dino-omemo.mo"
    [ -s "$missing_catalog" ] || return 1
    rm -f "$missing_catalog"
    if translation_catalog_inventory_issues "$root" "$PROJECT_ROOT" >/dev/null 2>&1; then
        return 1
    fi

    rm -rf "$root"
    trap - RETURN
}

assert_arg_validation() {
    local output rc

    if ! ( MODE=--help; validate_args --help ) >/dev/null 2>&1; then
        return 1
    fi
    if ( MODE=--help; validate_args --help extra ) >/dev/null 2>&1; then
        return 1
    elif [ "$?" -ne 2 ]; then
        return 1
    fi

    if ! ( MODE=help; validate_args help ) >/dev/null 2>&1; then
        return 1
    fi

    if ! "$0" --help | grep -qF "system [BUILD_DIR]|local [BUILD_DIR]"; then
        return 1
    fi

    if ( MODE=help; validate_args help extra ) >/dev/null 2>&1; then
        return 1
    elif [ "$?" -ne 2 ]; then
        return 1
    fi

    if ( MODE=metadata; validate_args metadata extra ) >/dev/null 2>&1; then
        return 1
    elif [ "$?" -ne 2 ]; then
        return 1
    fi

    if ! ( MODE=system; validate_args system ) >/dev/null 2>&1; then
        return 1
    fi

    if ! ( MODE=system; validate_args system "package build" ) >/dev/null 2>&1; then
        return 1
    fi
    if ( MODE=system; validate_args system build extra ) >/dev/null 2>&1; then
        return 1
    elif [ "$?" -ne 2 ]; then
        return 1
    fi

    if ! ( MODE=local; validate_args local ) >/dev/null 2>&1; then
        return 1
    fi

    if ! ( MODE=local; validate_args local "package build" ) >/dev/null 2>&1; then
        return 1
    fi
    if ( MODE=local; validate_args local build extra ) >/dev/null 2>&1; then
        return 1
    elif [ "$?" -ne 2 ]; then
        return 1
    fi

    if ! ( MODE=self-test; validate_args self-test ) >/dev/null 2>&1; then
        return 1
    fi

    if ( MODE=self-test; validate_args self-test extra ) >/dev/null 2>&1; then
        return 1
    elif [ "$?" -ne 2 ]; then
        return 1
    fi

    if ! ( MODE=deb; validate_args deb dinox-test.deb ) >/dev/null 2>&1; then
        return 1
    fi

    if ( MODE=deb; validate_args deb one.deb two.deb ) >/dev/null 2>&1; then
        return 1
    elif [ "$?" -ne 2 ]; then
        return 1
    fi

    if ! ( MODE=appdir; validate_args appdir AppDir ) >/dev/null 2>&1; then
        return 1
    fi

    if ( MODE=appdir; validate_args appdir AppDir extra ) >/dev/null 2>&1; then
        return 1
    elif [ "$?" -ne 2 ]; then
        return 1
    fi

    if ! ( MODE=flatpak-manifest; validate_args flatpak-manifest im.dinox.dinox.json ) >/dev/null 2>&1; then
        return 1
    fi

    if ( MODE=flatpak-manifest; validate_args flatpak-manifest one two ) >/dev/null 2>&1; then
        return 1
    elif [ "$?" -ne 2 ]; then
        return 1
    fi

    if output="$("$0" __dinox_unknown_mode__ 2>&1)"; then
        return 1
    else
        rc=$?
    fi
    if [ "$rc" -ne 2 ] || ! grep -qF "Unbekannter Modus: __dinox_unknown_mode__" <<< "$output"; then
        return 1
    fi
}

assert_flatpak_manifest_module_config_checks() {
    have_cmd jq || return 0

    local tmp_dir manifest output rc
    tmp_dir="$(mktemp -d)"
    manifest="$tmp_dir/manifest.json"
    rc=0
    cat > "$manifest" <<'EOF'
{
  "modules": [
    {
      "name": "dino",
      "config-opts": [
        "-Dplugin-rtp=disabled"
      ]
    }
  ]
}
EOF

    output="$(manifest_module_config_has "$manifest" "dino" "-Dplugin-rtp=disabled" "Altes RTP Plugin deaktiviert" 2>&1)"
    if ! grep -qF "[OK]   Altes RTP Plugin deaktiviert" <<< "$output"; then
        rc=1
    fi

    output="$(manifest_module_config_has "$manifest" "dino" "-Dmissing" "Altes RTP Plugin deaktiviert" 2>&1)"
    if ! grep -qF "[FAIL] Altes RTP Plugin deaktiviert fehlt (dino: -Dmissing)" <<< "$output"; then
        rc=1
    fi

    rm -rf "$tmp_dir"
    return "$rc"
}

assert_missing_target_failures() {
    local output rc target

    target="/tmp/dinox-matrix-missing-appdir-$$"
    if output="$("$0" appdir "$target" 2>&1)"; then
        return 1
    else
        rc=$?
    fi
    if [ "$rc" -ne 1 ] || ! grep -qF "AppDir fehlt ($target)" <<< "$output"; then
        return 1
    fi

    target="/tmp/dinox-matrix-missing-package-$$.deb"
    if output="$("$0" deb "$target" 2>&1)"; then
        return 1
    else
        rc=$?
    fi
    if [ "$rc" -ne 1 ] || ! grep -qF "Debian-Paket nicht gefunden ($target)" <<< "$output"; then
        return 1
    fi

    target="/tmp/dinox-matrix-missing-flatpak-manifest-$$.json"
    if output="$("$0" flatpak-manifest "$target" 2>&1)"; then
        return 1
    else
        rc=$?
    fi
    if [ "$rc" -ne 1 ] || ! grep -qF "Manifest fehlt ($target)" <<< "$output"; then
        return 1
    fi

    target="$(mktemp -d)"
    mkdir -p "$target/usr/lib/dinox"
    if output="$("$0" appdir "$target" 2>&1)"; then
        rm -rf "$target"
        return 1
    else
        rc=$?
    fi
    rm -rf "$target"
    if [ "$rc" -ne 1 ] \
        || ! grep -qF "[FAIL] AppDir Desktop-Datei fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] AppDir Root-Icon fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] AppDir .DirIcon fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] AppDir AppStream Metainfo fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] D-Bus Service-Datei fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] ffmpeg Binary für Nachrichten-Recorder fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] OpenPGP gpg fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] OpenPGP gpgconf fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] OpenPGP gpg-agent fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] OpenPGP dirmngr fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] OpenPGP gpg-connect-agent fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] OpenPGP Keyserver-curl fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] GnuPG relocatable Konfiguration fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] GnuPG Keyserver-CA fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] Google/libwebrtc Notice LICENSE.md fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] AppImage Drittanbieter-Lizenzen/BOM fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] libomemo-c fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] libnice fehlt" <<< "$output" \
        || ! grep -qF "[FAIL] libmosquitto fehlt" <<< "$output"; then
        return 1
    fi
    if ! output_has_appdir_gstreamer_plugin_failures "$output"; then
        return 1
    fi

    target="$(mktemp -d)"
    printf '#!/bin/sh\nexec "$@"\n' > "$target/AppRun"
    chmod +x "$target/AppRun"
    if output="$("$0" appdir "$target" 2>&1)"; then
        rm -rf "$target"
        return 1
    else
        rc=$?
    fi
    rm -rf "$target"
    if [ "$rc" -ne 1 ] \
        || ! grep -qF "AppRun private Bibliothekspfade fehlt" <<< "$output" \
        || ! grep -qF "AppRun GStreamer Pluginpfad fehlt" <<< "$output" \
        || ! grep -qF "AppRun Dino Pluginpfad fehlt" <<< "$output" \
        || ! grep -qF "AppRun Übersetzungspfad fehlt" <<< "$output" \
        || ! grep -qF "AppRun Tor-Pfad fehlt" <<< "$output" \
        || ! grep -qF "AppRun Tor-Datenpfad fehlt" <<< "$output" \
        || ! grep -qF "AppRun Lyrebird-Pfad fehlt" <<< "$output" \
        || ! grep -qF "AppRun ffmpeg-Pfad fehlt" <<< "$output" \
        || ! grep -qF "AppRun OpenPGP curl CA-Pfad fehlt" <<< "$output" \
        || ! grep -qF "AppRun OpenPGP curl CA-Bundle fehlt" <<< "$output" \
        || ! grep -qF "AppRun XDG Datenpfad fehlt" <<< "$output" \
        || ! grep -qF "AppRun GSettings Schemapfad fehlt" <<< "$output" \
        || ! grep -qF "AppRun AT-SPI Direktprobe fehlt" <<< "$output" \
        || ! grep -qF "AppRun AT-SPI Probe-Zeitlimit fehlt" <<< "$output" \
        || ! grep -qF "AppRun AT-SPI Registry-Reparatur fehlt" <<< "$output" \
        || ! grep -qF "AppRun Desktop-Datei Hint fehlt" <<< "$output" \
        || ! grep -qF "AppRun leerzeichenfester Desktop Exec-Hint fehlt" <<< "$output" \
        || ! grep -qF "AppRun BAMF Desktop-Datei Hint fehlt" <<< "$output" \
        || ! grep -qF "AppRun XDG Sprachdatei fehlt" <<< "$output" \
        || ! grep -qF "AppRun Sprachdatei Default fehlt" <<< "$output"; then
        return 1
    fi
}

assert_deb_wrapper_checks() {
    have_cmd dpkg-deb || return 0
    have_cmd tar || return 0

    local tmp_dir pkg deb output rc
    tmp_dir="$(mktemp -d)"
    pkg="$tmp_dir/pkg"
    deb="$tmp_dir/dinox-test.deb"
    mkdir -p "$pkg/DEBIAN" "$pkg/usr/bin"
    cat > "$pkg/DEBIAN/control" <<'EOF'
Package: dinox-test
Version: 1.0
Architecture: all
Maintainer: DinoX
Description: DinoX matrix self-test package
EOF
    printf '#!/bin/sh\nexec "$(dirname "$0")/dinox.real" "$@"\n' > "$pkg/usr/bin/dinox"
    printf '#!/bin/sh\nexit 0\n' > "$pkg/usr/bin/dinox.real"
    chmod 755 "$pkg/usr/bin/dinox" "$pkg/usr/bin/dinox.real"

    if ! dpkg-deb --build "$pkg" "$deb" >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        return 1
    fi

    if output="$("$0" deb "$deb" 2>&1)"; then
        rm -rf "$tmp_dir"
        return 1
    else
        rc=$?
    fi
    rm -rf "$tmp_dir"
    if [ "$rc" -ne 1 ] \
        || ! grep -qF "Deb libsoup 3.4 Dependency fehlt" <<< "$output" \
        || ! grep -qF "Deb ffmpeg Recorder Dependency fehlt" <<< "$output" \
        || ! grep -qF "Deb GStreamer Base Plugins Dependency fehlt" <<< "$output" \
        || ! grep -qF "Deb GStreamer Good Plugins Dependency fehlt" <<< "$output" \
        || ! grep -qF "Deb GStreamer Bad Plugins Dependency fehlt" <<< "$output" \
        || ! grep -qF "Deb GStreamer libav Decoder Dependency fehlt" <<< "$output" \
        || ! grep -qF "Deb OpenSSL Runtime Dependency fehlt" <<< "$output" \
        || ! grep -qF "Deb SRTP Runtime Dependency fehlt" <<< "$output" \
        || ! grep -qF "Deb libva Runtime Dependency fehlt" <<< "$output" \
        || ! grep -qF "Deb Wrapper private Bibliothekspfade fehlt" <<< "$output" \
        || ! grep -qF "Deb Wrapper Tor-Pfad fehlt" <<< "$output" \
        || ! grep -qF "Deb Wrapper Tor-Datenpfad fehlt" <<< "$output" \
        || ! grep -qF "Deb Wrapper Lyrebird-Pfad fehlt" <<< "$output" \
        || ! grep -qF "Deb Wrapper AT-SPI Direktprobe fehlt" <<< "$output" \
        || ! grep -qF "Deb Wrapper AT-SPI Probe-Zeitlimit fehlt" <<< "$output" \
        || ! grep -qF "Deb Wrapper AT-SPI Registry-Reparatur fehlt" <<< "$output" \
        || ! grep -qF "Tor Binary fehlt" <<< "$output" \
        || ! grep -qF "Lyrebird Binary fehlt" <<< "$output" \
        || ! grep -qF "DinoX Plugins fehlen" <<< "$output" \
        || ! grep -qF "DinoX Übersetzungen fehlen" <<< "$output" \
        || ! grep -qF "AppStream Metainfo fehlt" <<< "$output" \
        || ! grep -qF "AppStream Metainfo nicht lesbar" <<< "$output" \
        || ! grep -qF "AppStream ID nicht lesbar" <<< "$output" \
        || ! grep -qF "Desktop-Datei fehlt" <<< "$output" \
        || ! grep -qF "Desktop-Datei nicht lesbar" <<< "$output" \
        || ! grep -qF "Desktop Exec nicht lesbar" <<< "$output" \
        || ! grep -qF "Desktop Icon nicht lesbar" <<< "$output" \
        || ! grep -qF "Desktop XMPP Handler nicht lesbar" <<< "$output" \
        || ! grep -qF "Desktop Keyword DinoX nicht lesbar" <<< "$output" \
        || ! grep -qF "Desktop Keyword OMEMO nicht lesbar" <<< "$output" \
        || ! grep -qF "Desktop Keyword MQTT nicht lesbar" <<< "$output" \
        || ! grep -qF "Desktop Keyword Botmother nicht lesbar" <<< "$output" \
        || ! grep -qF "Desktop StartupWMClass nicht lesbar" <<< "$output" \
        || ! grep -qF "App-Icon 16x16 fehlt" <<< "$output" \
        || ! grep -qF "App-Icon 512x512 fehlt" <<< "$output" \
        || ! grep -qF "D-Bus Service-Datei fehlt" <<< "$output" \
        || ! grep -qF "D-Bus Service Name nicht lesbar" <<< "$output" \
        || ! grep -qF "D-Bus Service Exec nicht lesbar" <<< "$output" \
        || ! grep -qF "Deb Sprachinitialisierung fehlt" <<< "$output" \
        || ! grep -qF "Deb Sprach-Autostart fehlt" <<< "$output" \
        || ! grep -qF "Deb XDG Sprachdatei nicht lesbar" <<< "$output" \
        || ! grep -qF "Deb Sprachdatei Default nicht lesbar" <<< "$output" \
        || ! grep -qF "Deb Sprach-Autostart Exec nicht lesbar" <<< "$output" \
        || ! grep -qF "Google/libwebrtc Notice LICENSE.md fehlt" <<< "$output" \
        || ! grep -qF "Deb Copyright-Datei fehlt" <<< "$output" \
        || ! grep -qF "Deb Drittanbieter-Lizenzen/BOM fehlt" <<< "$output"; then
        return 1
    fi
}

assert_accessibility_wrapper_contract() {
    local builder

    for builder in \
        "$PROJECT_ROOT/scripts/build-deb.sh" \
        "$PROJECT_ROOT/scripts/build-appimage.sh"; do
        grep -qF "org.freedesktop.DBus.ListNames" "$builder" || return 1
        grep -qF "timeout 2 gdbus call" "$builder" || return 1
        grep -qF "$AT_SPI_REGISTRY_PGREP_PATTERN" "$builder" || return 1
    done
}

assert_appdir_desktop_checks() {
    local target output rc
    target="$(mktemp -d)"
    cat > "$target/im.dinox.dinox.desktop" <<'EOF'
[Desktop Entry]
Name=DinoX
Type=Application
EOF

    if output="$("$0" appdir "$target" 2>&1)"; then
        rm -rf "$target"
        return 1
    else
        rc=$?
    fi
    rm -rf "$target"
    if [ "$rc" -ne 1 ] \
        || ! grep -qF "AppDir Desktop Exec fehlt" <<< "$output" \
        || ! grep -qF "AppDir Desktop Icon fehlt" <<< "$output" \
        || ! grep -qF "AppDir Desktop XMPP Handler fehlt" <<< "$output" \
        || ! grep -qF "AppDir Desktop Keyword DinoX fehlt" <<< "$output" \
        || ! grep -qF "AppDir Desktop Keyword OMEMO fehlt" <<< "$output" \
        || ! grep -qF "AppDir Desktop Keyword MQTT fehlt" <<< "$output" \
        || ! grep -qF "AppDir Desktop Keyword Botmother fehlt" <<< "$output" \
        || ! grep -qF "AppDir Desktop StartupWMClass fehlt" <<< "$output"; then
        return 1
    fi
}

assert_appdir_desktop_files_match() {
    local target output rc
    target="$(mktemp -d)"
    mkdir -p "$target/usr/share/applications"
    printf '[Desktop Entry]\nName=DinoX\n' > "$target/im.dinox.dinox.desktop"
    printf '[Desktop Entry]\nName=DinoX Drift\n' > "$target/usr/share/applications/im.dinox.dinox.desktop"

    if output="$("$0" appdir "$target" 2>&1)"; then
        rm -rf "$target"
        return 1
    else
        rc=$?
    fi
    rm -rf "$target"
    if [ "$rc" -ne 1 ] || ! grep -qF "AppDir Desktop-Dateien identisch unterschiedlich" <<< "$output"; then
        return 1
    fi
}

assert_appdir_diricon_symlink() {
    local target output rc
    target="$(mktemp -d)"
    touch "$target/im.dinox.dinox.png" "$target/wrong.png"
    ln -s "wrong.png" "$target/.DirIcon"

    if output="$("$0" appdir "$target" 2>&1)"; then
        rm -rf "$target"
        return 1
    else
        rc=$?
    fi
    rm -rf "$target"
    if [ "$rc" -ne 1 ] || ! grep -qF "AppDir .DirIcon Ziel ungültig" <<< "$output"; then
        return 1
    fi
}

assert_appdir_icon_sizes() {
    local target output rc
    target="$(mktemp -d)"
    mkdir -p "$target/usr/share/icons/hicolor/256x256/apps"
    touch "$target/usr/share/icons/hicolor/256x256/apps/im.dinox.dinox.png"

    if output="$("$0" appdir "$target" 2>&1)"; then
        rm -rf "$target"
        return 1
    else
        rc=$?
    fi
    rm -rf "$target"
    if [ "$rc" -ne 1 ] \
        || ! grep -qF "App-Icon 16x16 fehlt" <<< "$output" \
        || ! grep -qF "App-Icon 512x512 fehlt" <<< "$output"; then
        return 1
    fi
}

assert_appstream_screenshot_assets() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local rc=0

    mkdir -p "$tmp_dir/docs/assets"
    python3 - "$tmp_dir/docs/assets/ok.png" <<'PY'
import struct
import sys
import zlib

path = sys.argv[1]


def chunk(kind, data):
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(b"\x00\x00\x00\x00"))
    + chunk(b"IEND", b"")
)
with open(path, "wb") as handle:
    handle.write(png)
PY
    cat > "$tmp_dir/appdata.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <screenshots>
    <screenshot>
      <image type="source" width="1" height="1">https://git.dinox.im/dinoxim/dinox/raw/branch/master/docs/assets/ok.png</image>
    </screenshot>
  </screenshots>
</component>
EOF

    if ! appstream_screenshot_assets_valid "$tmp_dir/appdata.xml" "$tmp_dir" false; then
        rc=1
    fi
    run_isolated_git -C "$tmp_dir" init -q
    run_isolated_git -C "$tmp_dir" add docs/assets/ok.png
    if ! appstream_screenshot_assets_valid "$tmp_dir/appdata.xml" "$tmp_dir" true; then
        rc=1
    fi

    cat > "$tmp_dir/appdata.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <screenshots>
    <screenshot>
      <image type="source" width="1" height="1">https://git.dinox.im/dinoxim/dinox/raw/tag/v2.0.0/docs/assets/ok.png</image>
    </screenshot>
  </screenshots>
</component>
EOF

    if ! appstream_screenshot_assets_valid "$tmp_dir/appdata.xml" "$tmp_dir" true; then
        rc=1
    fi

    cat > "$tmp_dir/appdata.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <screenshots>
    <screenshot>
      <image type="source" width="1" height="1">https://git.dinox.im/dinoxim/dinox/raw/commit/0123456789abcdef0123456789abcdef01234567/docs/assets/ok.png</image>
    </screenshot>
  </screenshots>
</component>
EOF

    if ! appstream_screenshot_assets_valid "$tmp_dir/appdata.xml" "$tmp_dir" true; then
        rc=1
    fi

    cp "$tmp_dir/docs/assets/ok.png" "$tmp_dir/docs/assets/untracked.png"
    cat > "$tmp_dir/appdata.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <screenshots>
    <screenshot>
      <image type="source" width="1" height="1">https://git.dinox.im/dinoxim/dinox/raw/branch/master/docs/assets/untracked.png</image>
    </screenshot>
  </screenshots>
</component>
EOF

    if appstream_screenshot_assets_valid "$tmp_dir/appdata.xml" "$tmp_dir" true; then
        rc=1
    fi

    cat > "$tmp_dir/appdata.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <screenshots>
    <screenshot>
      <image type="source">https://git.dinox.im/dinoxim/dinox/raw/branch/master/docs/assets/ok.png</image>
    </screenshot>
  </screenshots>
</component>
EOF

    if appstream_screenshot_assets_valid "$tmp_dir/appdata.xml" "$tmp_dir" false; then
        rc=1
    fi

    printf 'not a png\n' > "$tmp_dir/docs/assets/broken.png"
    cat > "$tmp_dir/appdata.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <screenshots>
    <screenshot>
      <image type="source" width="1" height="1">https://git.dinox.im/dinoxim/dinox/raw/branch/master/docs/assets/broken.png</image>
    </screenshot>
  </screenshots>
</component>
EOF

    if appstream_screenshot_assets_valid "$tmp_dir/appdata.xml" "$tmp_dir" false; then
        rc=1
    fi

    cat > "$tmp_dir/appdata.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <screenshots>
    <screenshot>
      <image type="source" width="2" height="1">https://git.dinox.im/dinoxim/dinox/raw/branch/master/docs/assets/ok.png</image>
    </screenshot>
  </screenshots>
</component>
EOF

    if appstream_screenshot_assets_valid "$tmp_dir/appdata.xml" "$tmp_dir" false; then
        rc=1
    fi

    cat > "$tmp_dir/appdata.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <screenshots>
    <screenshot>
      <image type="source">https://git.dinox.im/dinoxim/dinox/raw/branch/master/docs/assets/missing.png</image>
    </screenshot>
  </screenshots>
</component>
EOF

    if appstream_screenshot_assets_valid "$tmp_dir/appdata.xml" "$tmp_dir" false; then
        rc=1
    fi

    cat > "$tmp_dir/appdata.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <screenshots>
    <screenshot>
      <image type="source">https://example.invalid/screenshot.png</image>
    </screenshot>
  </screenshots>
</component>
EOF

    if appstream_screenshot_assets_valid "$tmp_dir/appdata.xml" "$tmp_dir" false; then
        rc=1
    fi

    rm -rf "$tmp_dir"
    return "$rc"
}

assert_ffmpeg_capability_parser() {
    local encoders muxers
    encoders=$' V....D libx264              H.264\n A....D aac                  AAC'
    muxers=$'  E ipod            iPod H.264 MP4\n  E mp4             MP4'

    ffmpeg_capability_present "$encoders" aac \
        && ffmpeg_capability_present "$encoders" libx264 \
        && ! ffmpeg_capability_present "$encoders" libopenh264 \
        && ffmpeg_capability_present "$muxers" ipod \
        && ffmpeg_capability_present "$muxers" mp4 \
        && ! ffmpeg_capability_present "$muxers" matroska
}

assert_ffmpeg_missing_encoder_does_not_abort() {
    local tmp_dir fake_ffmpeg output
    tmp_dir="$(mktemp -d)"
    fake_ffmpeg="$tmp_dir/ffmpeg"
    cat > "$fake_ffmpeg" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *" -encoders "*)
        printf ' A....D aac                  AAC\n'
        ;;
    *" -muxers "*)
        printf '  E ipod            iPod H.264 MP4\n  E mp4             MP4\n'
        ;;
    *)
        exit 2
        ;;
esac
EOF
    chmod +x "$fake_ffmpeg"

    if ! output="$({
        set -e
        diagnose_linux_ffmpeg_recorder "$fake_ffmpeg" "" "Fake ffmpeg" libx264
        printf '%s\n' REACHED_AFTER_MISSING_ENCODER
    } 2>&1)"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"
    grep -qF '[FAIL] ffmpeg privater libx264 H.264-Encoder fehlt' <<< "$output" \
        && grep -qF 'REACHED_AFTER_MISSING_ENCODER' <<< "$output"
}

assert_ffmpeg_copy_mux_does_not_inherit_stdin() {
    local tmp_dir fake_ffmpeg output
    tmp_dir="$(mktemp -d)"
    fake_ffmpeg="$tmp_dir/ffmpeg"
    cat > "$fake_ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -eu
output_file="${!#}"
case " $* " in
    *" -c copy "*)
        if IFS= read -r _; then
            exit 9
        fi
        ;;
    *)
        cat >/dev/null
        ;;
esac
printf 'fixture\n' > "$output_file"
EOF
    chmod +x "$fake_ffmpeg"

    output="$({
        ok_count=0
        warn_count=0
        fail_count=0
        diagnose_ffmpeg_writer_smoke "$fake_ffmpeg" "" libx264 "Fake ffmpeg"
        printf 'FAIL_COUNT=%s\n' "$fail_count"
    } <<< 'INHERITED_STDIN_MUST_NOT_REACH_COPY_MUX')"

    rm -rf "$tmp_dir"
    grep -qF '[OK]   Fake ffmpeg echtes Audio/Video-Copy-Muxing' <<< "$output" \
        && grep -qF 'FAIL_COUNT=0' <<< "$output"
}

assert_gnupg_version_parser() {
    [ "$(printf '%s\n' 'gpg (GnuPG) 2.4.4' | gnupg_version_from_output)" = "2.4.4" ] \
        && [ "$(printf '%s\n' 'dirmngr (GnuPG) 2.4.10' | gnupg_version_from_output)" = "2.4.10" ] \
        && [ -z "$(printf '%s\n' 'curl 8.5.0' | gnupg_version_from_output)" ]
}

assert_google_notice_inventory() {
    local expected actual
    expected=$'LICENSE\nLICENSE.md\nPATENTS\nmanifest.json\nFFMPEG-LICENSE\nLIBVA-LICENSE\nFFMPEG-VP8-VAAPI.json\nNVIDIA-CODEC-HEADERS-LICENSE\nWEBRTC-CODECS.json\nWEBRTC-GN-ARGS.gn'
    actual="$(google_libwebrtc_notice_files)"
    [ "$actual" = "$expected" ] \
        && [ "$(sort -u <<< "$actual" | wc -l)" -eq 10 ]
}

assert_elf_host_abi_allowlist() {
    elf_host_abi_allowed appdir libc.so.6 \
        && elf_host_abi_allowed appdir libX11.so.6 \
        && ! elf_host_abi_allowed appdir libgpg-error.so.0 \
        && ! elf_host_abi_allowed appdir libicuuc.so.74 \
        && ! elf_host_abi_allowed appdir libomemo-c.so.0 \
        && elf_host_abi_allowed deb libgtk-4.so.1 \
        && elf_host_abi_allowed deb libicuuc.so.74 \
        && elf_host_abi_allowed deb libicui18n.so.74 \
        && elf_host_abi_allowed deb libicudata.so.74 \
        && ! elf_host_abi_allowed deb libdinox-google-webrtc.so
}

assert_static_all_elf_closure() {
    local tmp_dir root fake_readelf output
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    fake_readelf="$tmp_dir/readelf"
    mkdir -p \
        "$root/usr/bin" \
        "$root/usr/lib/dinox" \
        "$root/usr/lib/private" \
        "$root/usr/share/unreachable"
    touch \
        "$root/usr/bin/test-app" \
        "$root/usr/bin/test-rpath" \
        "$root/usr/lib/libprovided.so.1" \
        "$root/usr/lib/dinox/liblauncher.so.1" \
        "$root/usr/lib/private/librpath.so.1"
    cat > "$fake_readelf" <<'EOF'
#!/usr/bin/env bash
set -e
mode="$1"
path="${3:-${2:-}}"
case "$mode" in
    -h)
        exit 0
        ;;
    -d)
        case "$(basename "$path")" in
            test-app)
                echo ' 0x0000000000000001 (NEEDED)             Shared library: [libprovided.so.1]'
                echo ' 0x0000000000000001 (NEEDED)             Shared library: [libmissing-private.so.9]'
                echo ' 0x0000000000000001 (NEEDED)             Shared library: [liblauncher.so.1]'
                echo ' 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]'
                ;;
            test-rpath)
                echo ' 0x0000000000000001 (NEEDED)             Shared library: [librpath.so.1]'
                echo ' 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN/../lib/private]'
                ;;
        esac
        ;;
    *)
        exit 2
        ;;
esac
EOF
    chmod +x "$fake_readelf"

    if output="$(DINOX_READELF="$fake_readelf" elf_closure_issues "$root" appdir)"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! grep -qF 'usr/bin/test-app -> libmissing-private.so.9' <<< "$output" \
            || grep -qF 'libprovided.so.1' <<< "$output" \
            || grep -qF 'liblauncher.so.1' <<< "$output" \
            || grep -qF 'librpath.so.1' <<< "$output" \
            || grep -qF 'libc.so.6' <<< "$output"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    # An identical basename outside every loader-visible path must not satisfy
    # the package closure.
    touch "$root/usr/share/unreachable/libmissing-private.so.9"
    if output="$(DINOX_READELF="$fake_readelf" elf_closure_issues "$root" appdir)" \
            || ! grep -qF 'usr/bin/test-app -> libmissing-private.so.9' <<< "$output"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    touch "$root/usr/lib/libmissing-private.so.9"
    if ! DINOX_READELF="$fake_readelf" elf_closure_issues "$root" appdir >/dev/null; then
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
}

assert_release_forbidden_artifact_gate() {
    local tmp_dir root fake_readelf output
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    fake_readelf="$tmp_dir/readelf"
    mkdir -p \
        "$root/usr/lib/dino/plugins" \
        "$root/usr/lib/dinox" \
        "$root/usr/share/dinox"
    printf 'release payload\n' > "$root/usr/share/dinox/allowed.txt"
    cat > "$fake_readelf" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-h" ]
EOF
    chmod +x "$fake_readelf"

    if ! DINOX_READELF="$fake_readelf" \
            release_forbidden_artifact_issues "$root" >/dev/null; then
        rm -rf "$tmp_dir"
        return 1
    fi

    touch \
        "$root/usr/lib/dino/plugins/rtp.so" \
        "$root/usr/lib/dinox/dinox-webrtc-process-smoke"
    printf 'binary-prefix DINOX_WEBRTC_ENABLE_IN_PROCESS_TEST_ORACLE binary-suffix\n' \
        > "$root/usr/lib/dinox/libdinox-google-webrtc.so"
    if output="$(DINOX_READELF="$fake_readelf" \
            release_forbidden_artifact_issues "$root")"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! grep -qF 'dino/plugins/rtp.so: altes GStreamer-RTP-Plugin' <<< "$output" \
            || ! grep -qF 'dinox-webrtc-process-smoke: WebRTC-Testartefakt' <<< "$output" \
            || ! grep -qF 'libdinox-google-webrtc.so: WebRTC-Test-Oracle-Marker' <<< "$output"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
}

assert_bot_features_omemo_runtime_paths() {
    local tmp_dir root fake_readelf output
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    fake_readelf="$tmp_dir/readelf"
    mkdir -p "$root/usr/lib/x86_64-linux-gnu/dino/plugins"
    touch \
        "$root/usr/lib/x86_64-linux-gnu/dino/plugins/bot-features.so" \
        "$root/usr/lib/x86_64-linux-gnu/dino/plugins/omemo.so"
    cat > "$fake_readelf" <<'EOF'
#!/usr/bin/env bash
set -e
mode="$1"
path="${3:-${2:-}}"
case "$mode" in
    -h)
        case "$(basename "$path")" in
            bot-features.so|omemo.so)
                exit 0
                ;;
        esac
        exit 1
        ;;
    -d)
        if [ "$(basename "$path")" = "bot-features.so" ]; then
            runtime_path="${DINOX_TEST_BOT_RUNPATH:-}"
            [ -n "$runtime_path" ] || runtime_path='$ORIGIN'
            printf ' 0x0000000000000001 (NEEDED)             Shared library: [omemo.so]\n'
            printf ' 0x000000000000001d (RUNPATH)            Library runpath: [%s]\n' "$runtime_path"
        fi
        ;;
    *)
        exit 2
        ;;
esac
EOF
    chmod +x "$fake_readelf"

    local DINOX_TEST_BOT_RUNPATH=""
    export DINOX_TEST_BOT_RUNPATH
    if ! DINOX_READELF="$fake_readelf" elf_absolute_runtime_path_issues "$root" >/dev/null \
            || ! DINOX_READELF="$fake_readelf" bot_features_omemo_resolution_issues "$root" >/dev/null; then
        rm -rf "$tmp_dir"
        return 1
    fi

    DINOX_TEST_BOT_RUNPATH='/workspace/build-deb-package/plugins/omemo'
    if output="$(DINOX_READELF="$fake_readelf" elf_absolute_runtime_path_issues "$root")"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! grep -qF 'bot-features.so -> /workspace/build-deb-package/plugins/omemo' <<< "$output"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    DINOX_TEST_BOT_RUNPATH='$ORIGIN/../omemo'
    if DINOX_READELF="$fake_readelf" bot_features_omemo_resolution_issues "$root" >/dev/null; then
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
}

assert_google_webrtc_runtime_paths() {
    local tmp_dir root fake_readelf output
    tmp_dir="$(mktemp -d)"
    root="$tmp_dir/root"
    fake_readelf="$tmp_dir/readelf"
    mkdir -p \
        "$root/usr/lib/x86_64-linux-gnu/dino/plugins" \
        "$root/usr/lib/dinox"
    touch \
        "$root/usr/lib/x86_64-linux-gnu/dino/plugins/google-webrtc.so" \
        "$root/usr/lib/x86_64-linux-gnu/libdino.so.0" \
        "$root/usr/lib/dinox/libdinox-google-webrtc.so" \
        "$root/usr/lib/dinox/libavcodec-dinox-hw.so.62" \
        "$root/usr/lib/dinox/libavutil-dinox-hw.so.60" \
        "$root/usr/lib/dinox/dinox-webrtc-worker"
    chmod +x "$root/usr/lib/dinox/dinox-webrtc-worker"
    cat > "$fake_readelf" <<'EOF'
#!/usr/bin/env bash
set -e
mode="$1"
path="${3:-${2:-}}"
case "$mode" in
    -h)
        exit 0
        ;;
    -d)
        case "$(basename "$path")" in
            google-webrtc.so)
                printf ' 0x0000000000000001 (NEEDED)             Shared library: [libdinox-google-webrtc.so]\n'
                printf ' 0x0000000000000001 (NEEDED)             Shared library: [libdino.so.0]\n'
                printf ' 0x000000000000001d (RUNPATH)            Library runpath: [%s]\n' \
                    "${DINOX_TEST_GOOGLE_PLUGIN_RUNPATH:-\$ORIGIN/../..:\$ORIGIN/../../../dinox}"
                ;;
            libdinox-google-webrtc.so)
                printf ' 0x0000000000000001 (NEEDED)             Shared library: [libavcodec-dinox-hw.so.62]\n'
                printf ' 0x0000000000000001 (NEEDED)             Shared library: [libavutil-dinox-hw.so.60]\n'
                printf ' 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN]\n'
                ;;
            dinox-webrtc-worker)
                printf ' 0x0000000000000001 (NEEDED)             Shared library: [libdinox-google-webrtc.so]\n'
                printf ' 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN]\n'
                ;;
        esac
        ;;
    *)
        exit 2
        ;;
esac
EOF
    chmod +x "$fake_readelf"

    local DINOX_TEST_GOOGLE_PLUGIN_RUNPATH='$ORIGIN/../..:$ORIGIN/../../../dinox'
    export DINOX_TEST_GOOGLE_PLUGIN_RUNPATH
    if ! DINOX_READELF="$fake_readelf" google_webrtc_runtime_path_issues "$root" >/dev/null; then
        rm -rf "$tmp_dir"
        return 1
    fi

    DINOX_TEST_GOOGLE_PLUGIN_RUNPATH='$ORIGIN/../..:$ORIGIN/../../dinox'
    if output="$(DINOX_READELF="$fake_readelf" google_webrtc_runtime_path_issues "$root")"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! grep -qF 'relativer $ORIGIN-Pfad löst den privaten Wrapper-Pfad' <<< "$output"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
}

assert_distribution_provenance_gate() {
    local tmp_dir appdir source_root inventory payload payload_sha payload_size dsc target_sha source_tree
    tmp_dir="$(mktemp -d)"
    appdir="$tmp_dir/AppDir"
    source_root="$appdir/usr/share/licenses/dinox/corresponding-sources/distribution/fixture"
    inventory="$appdir/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv"
    mkdir -p \
        "$appdir/usr/lib" \
        "$appdir/usr/share/licenses/dinox/system-packages/fixture-bin" \
        "$source_root"

    printf 'fixture runtime\n' > "$appdir/usr/lib/libfixture.so"
    printf 'fixture copyright\n' \
        > "$appdir/usr/share/licenses/dinox/system-packages/fixture-bin/copyright"
    source_tree="$tmp_dir/fixture-1.0"
    mkdir -p "$source_tree/debian/source"
    printf '3.0 (native)\n' > "$source_tree/debian/source/format"
    printf 'fixture (1.0) unstable; urgency=medium\n\n  * Matrix compliance fixture.\n\n -- DinoX Team <contact@dinox.im>  Wed, 22 Jul 2026 00:00:00 +0000\n' \
        > "$source_tree/debian/changelog"
    printf 'Source: fixture\nSection: misc\nPriority: optional\nMaintainer: DinoX Team <contact@dinox.im>\nStandards-Version: 4.6.2\n\nPackage: fixture-bin\nArchitecture: any\nDescription: matrix compliance fixture\n' \
        > "$source_tree/debian/control"
    (cd "$tmp_dir" && dpkg-source -b fixture-1.0 >/dev/null 2>&1) || {
        rm -rf "$tmp_dir"
        return 1
    }
    find "$tmp_dir" -maxdepth 1 -type f \
        \( -name 'fixture_1.0.dsc' -o -name 'fixture_1.0.tar.*' \) \
        -exec cp -a '{}' "$source_root/" ';'
    dsc="$(find "$source_root" -maxdepth 1 -type f -name '*.dsc' -print -quit)"
    payload="$(find "$source_root" -maxdepth 1 -type f -name '*.tar.*' -print -quit)"
    [ -s "$dsc" ] && [ -s "$payload" ] || { rm -rf "$tmp_dir"; return 1; }
    (cd "$source_root" && sha256sum "$(basename "$dsc")" "$(basename "$payload")" > SHA256SUMS)
    {
        printf 'source_package=fixture\n'
        printf 'source_version=1.0\n'
        printf 'binary_packages=fixture-bin:amd64\n'
        printf 'source_format=debian-source-package\n'
    } > "$source_root/METADATA"

    target_sha="$(sha256sum "$appdir/usr/lib/libfixture.so" | awk '{ print $1 }')"
    printf 'package_path\thost_source_path\tbinary_package\tbinary_version\tarchitecture\tsource_package\tsource_version\tpackaged_sha256\thost_source_sha256\ttransform\tcopyright_path\n' \
        > "$inventory"
    printf 'usr/lib/libfixture.so\t/usr/lib/x86_64-linux-gnu/libfixture.so\tfixture-bin:amd64\t1.0\tamd64\tfixture\t1.0\t%s\t%s\tverbatim-copy\t/usr/share/doc/fixture-bin/copyright\n' \
        "$target_sha" "$target_sha" >> "$inventory"

    if ! validate_appdir_distribution_provenance "$appdir"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    printf 'fixture runtime\n' > "$tmp_dir/outside-runtime"
    rm -f "$appdir/usr/lib/libfixture.so"
    ln -s "$tmp_dir/outside-runtime" "$appdir/usr/lib/libfixture.so"
    if validate_appdir_distribution_provenance "$appdir"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -f "$appdir/usr/lib/libfixture.so"
    printf 'fixture runtime\n' > "$appdir/usr/lib/libfixture.so"

    printf 'tampered\n' >> "$appdir/usr/lib/libfixture.so"
    if validate_appdir_distribution_provenance "$appdir"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    printf 'fixture runtime\n' > "$appdir/usr/lib/libfixture.so"

    printf 'not an extractable source archive\n' > "$payload"
    payload_sha="$(sha256sum "$payload" | awk '{ print $1 }')"
    payload_size="$(wc -c < "$payload")"
    awk -v sha="$payload_sha" -v size="$payload_size" -v name="$(basename "$payload")" '
        /^Checksums-Sha256:/ { in_sha256 = 1; print; next }
        in_sha256 && /^ / && $3 == name { print " " sha " " size " " name; next }
        in_sha256 && !/^ / { in_sha256 = 0 }
        { print }
    ' "$dsc" > "$dsc.tmp"
    mv "$dsc.tmp" "$dsc"
    (cd "$source_root" && sha256sum "$(basename "$dsc")" "$(basename "$payload")" > SHA256SUMS)
    if validate_appdir_distribution_provenance "$appdir"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"
}

assert_appimage_source_split_gate() {
    local tmp_dir appdir license_root extracted_root payload_inventory relative
    local payload_size payload_checksum
    tmp_dir="$(mktemp -d)"
    appdir="$tmp_dir/AppDir"
    license_root="$appdir/usr/share/licenses/dinox"
    extracted_root="$tmp_dir/extracted"
    payload_inventory="$license_root/SOURCE_PAYLOADS.tsv"
    mkdir -p \
        "$license_root/corresponding-sources/distribution/fixture" \
        "$license_root/corresponding-sources/recorder-ffmpeg" \
        "$license_root/google-libwebrtc/sources" \
        "$license_root/dinox"
    printf 'DinoX license fixture\n' > "$license_root/dinox/LICENSE"
    printf 'source_package=fixture\n' \
        > "$license_root/corresponding-sources/distribution/fixture/METADATA"
    printf 'fixture checksums\n' \
        > "$license_root/corresponding-sources/distribution/fixture/SHA256SUMS"
    printf 'recorder metadata\n' \
        > "$license_root/corresponding-sources/recorder-ffmpeg/METADATA"
    printf 'distribution source\n' \
        > "$license_root/corresponding-sources/distribution/fixture/fixture_1.0.dsc"
    printf 'recorder source\n' \
        > "$license_root/corresponding-sources/recorder-ffmpeg/ffmpeg-fixture.tar.xz"
    printf 'webrtc source\n' \
        > "$license_root/google-libwebrtc/sources/webrtc-fixture.tar.xz"

    {
        printf 'relative_path\tsize\tsha256\n'
        for relative in \
            corresponding-sources/distribution/fixture/fixture_1.0.dsc \
            corresponding-sources/recorder-ffmpeg/ffmpeg-fixture.tar.xz \
            google-libwebrtc/sources/webrtc-fixture.tar.xz; do
            payload_size="$(stat -c '%s' -- "$license_root/$relative")"
            payload_checksum="$(sha256sum -- "$license_root/$relative" | awk '{ print $1 }')"
            printf '%s\t%s\t%s\n' "$relative" "$payload_size" "$payload_checksum"
        done
    } > "$payload_inventory"
    {
        printf '# DinoX AppImage corresponding sources\n\n'
        printf 'source_bundle=DinoX-fixture.AppImage.sources.tar.xz\n'
        printf 'payload_inventory=SOURCE_PAYLOADS.tsv\n'
        printf 'bundle_checksum=SOURCE_BUNDLE.sha256\n'
    } > "$license_root/SOURCE_OFFER.md"

    if ! validate_appimage_source_payload_inventory "$license_root" full; then
        rm -rf "$tmp_dir"
        return 1
    fi
    cp -a "$license_root/." "$extracted_root/"
    printf '%064d  DinoX-fixture.AppImage.sources.tar.xz\n' 0 \
        > "$license_root/SOURCE_BUNDLE.sha256"
    while IFS=$'\t' read -r relative _; do
        [ "$relative" = "relative_path" ] && continue
        rm -f -- "$license_root/$relative"
    done < "$payload_inventory"

    if ! validate_slim_appdir_source_offer "$appdir" \
            || ! validate_appdir_source_sidecar_provenance "$appdir" "$extracted_root"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    chmod 0600 "$payload_inventory"
    if validate_slim_appdir_source_offer "$appdir"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    chmod 0644 "$payload_inventory"

    chmod 0600 "$license_root/SOURCE_OFFER.md"
    if validate_slim_appdir_source_offer "$appdir"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    chmod 0644 "$license_root/SOURCE_OFFER.md"

    chmod 0600 "$license_root/SOURCE_BUNDLE.sha256"
    if validate_slim_appdir_source_offer "$appdir"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    chmod 0644 "$license_root/SOURCE_BUNDLE.sha256"

    printf 'payload returned\n' \
        > "$license_root/google-libwebrtc/sources/webrtc-fixture.tar.xz"
    if validate_slim_appdir_source_offer "$appdir"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -f "$license_root/google-libwebrtc/sources/webrtc-fixture.tar.xz"

    printf 'tampered payload\n' \
        >> "$extracted_root/google-libwebrtc/sources/webrtc-fixture.tar.xz"
    if validate_appdir_source_sidecar_provenance "$appdir" "$extracted_root"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    printf 'webrtc source\n' \
        > "$extracted_root/google-libwebrtc/sources/webrtc-fixture.tar.xz"

    mv \
        "$extracted_root/google-libwebrtc/sources/webrtc-fixture.tar.xz" \
        "$extracted_root/google-libwebrtc/sources/webrtc-fixture.tar.xz.missing"
    if validate_appdir_source_sidecar_provenance "$appdir" "$extracted_root"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    mv \
        "$extracted_root/google-libwebrtc/sources/webrtc-fixture.tar.xz.missing" \
        "$extracted_root/google-libwebrtc/sources/webrtc-fixture.tar.xz"

    printf 'additional payload\n' \
        > "$extracted_root/google-libwebrtc/sources/additional.tar.xz"
    if validate_appdir_source_sidecar_provenance "$appdir" "$extracted_root"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -f "$extracted_root/google-libwebrtc/sources/additional.tar.xz"

    printf 'sidecar deviation\n' > "$extracted_root/dinox/UNLISTED"
    if validate_appdir_source_sidecar_provenance "$appdir" "$extracted_root"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -f "$extracted_root/dinox/UNLISTED"

    mkdir "$extracted_root/UNLISTED-DIRECTORY"
    if validate_appdir_source_sidecar_provenance "$appdir" "$extracted_root"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    rmdir "$extracted_root/UNLISTED-DIRECTORY"

    cp "$license_root/SOURCE_BUNDLE.sha256" "$extracted_root/SOURCE_BUNDLE.sha256"
    if validate_appdir_source_sidecar_provenance "$appdir" "$extracted_root"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -f "$extracted_root/SOURCE_BUNDLE.sha256"

    printf '../escape.tar.xz\t1\t%064d\n' 0 \
        >> "$extracted_root/SOURCE_PAYLOADS.tsv"
    if validate_appdir_source_sidecar_provenance "$appdir" "$extracted_root"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    cp "$license_root/SOURCE_PAYLOADS.tsv" "$extracted_root/SOURCE_PAYLOADS.tsv"

    ln -s /etc/passwd "$extracted_root/google-libwebrtc/sources/escape.tar.xz"
    if validate_appdir_source_sidecar_provenance "$appdir" "$extracted_root"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -f "$extracted_root/google-libwebrtc/sources/escape.tar.xz"

    sed -i 's/DinoX-fixture/DinoX-other/' "$license_root/SOURCE_BUNDLE.sha256"
    if validate_slim_appdir_source_offer "$appdir"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    rm -rf "$tmp_dir"
}

assert_appimage_runtime_gate_contract() {
    local gate_root="ci/images/appimage-runtime-gate"
    local dockerfile="$gate_root/Dockerfile"
    local packages_file="$gate_root/packages.txt"
    local gate_script="$gate_root/run-gate.sh"
    local workflow=".github/workflows/build.yml"
    local package
    local -a required_packages=(
        libasound2t64
        libfontconfig1
        libgl1
        libwayland-client0
        libx11-6
    )

    [ -s "$dockerfile" ] \
        && [ -s "$packages_file" ] \
        && [ -s "$gate_script" ] \
        && [ -s "$workflow" ] \
        || return 1
    grep -Eq '^ARG DEBIAN_13_BASE="debian:13@sha256:[0-9a-f]{64}"$' \
        "$dockerfile" \
        || return 1
    grep -qF 'apt-get download ${packages}' "$dockerfile" \
        && grep -qF 'dpkg-deb --extract' "$dockerfile" \
        && grep -Fxq 'USER 65534:65534' "$dockerfile" \
        && ! grep -Eq 'apt-get[[:space:]]+install' "$dockerfile" \
        || return 1

    while IFS= read -r package; do
        case "$package" in
            ""|\#*) continue ;;
        esac
        [[ "$package" =~ ^[a-z0-9.+-]+$ ]] || return 1
        case "$package" in
            libgtk*|libadwaita*|libglib*|libgstreamer*|libgst*|\
            libcrypto*|libssl*|libgcrypt*|libsqlite*|libicu*)
                return 1
                ;;
        esac
    done < "$packages_file"
    for package in "${required_packages[@]}"; do
        grep -Fxq "$package" "$packages_file" || return 1
    done

    grep -qF 'APPIMAGE_EXTRACT_AND_RUN=1' "$gate_script" \
        && grep -qF -- '--launch gpg-agent' "$gate_script" \
        && grep -qF -- '--launch dirmngr' "$gate_script" \
        && grep -qF -- '--kill all' "$gate_script" \
        && grep -qF 'DinoX $EXPECTED_VERSION' "$gate_script" \
        || return 1
    grep -qF 'ci/images/appimage-runtime-gate' "$workflow" \
        && grep -qF -- '--network none' "$workflow" \
        && grep -qF -- '{{.Config.User}}' "$workflow" \
        || return 1
}

workflow_step_block() {
    local workflow="$1"
    local step_name="$2"
    local marker="      - name: \"$step_name\""

    awk -v marker="$marker" '
        capture && /^  [A-Za-z0-9_-]+:$/ {
            exit
        }
        /^      - name: / {
            if (capture) {
                exit
            }
            if ($0 == marker) {
                capture = 1
            }
        }
        capture { print }
    ' "$workflow"
}

workflow_artifact_paths() {
    awk '
        $0 == "          path: |" {
            capture = 1
            next
        }
        capture {
            if (substr($0, 1, 12) == "            " && substr($0, 13, 1) != " ") {
                print substr($0, 13)
                next
            }
            exit
        }
    '
}

assert_package_artifact_split_contract() {
    local workflow=".github/workflows/build.yml"
    local deb_block appimage_block source_block flatpak_block release_block block

    [ -s "$workflow" ] || return 1
    deb_block="$(workflow_step_block "$workflow" "Upload Debian Artifact")"
    appimage_block="$(workflow_step_block "$workflow" "Upload AppImage Package Artifact")"
    source_block="$(workflow_step_block "$workflow" "Upload AppImage Corresponding-Source Artifact")"
    flatpak_block="$(workflow_step_block "$workflow" "Upload Flatpak Artifact")"
    release_block="$(workflow_step_block "$workflow" "Upload AppImage Release Assets")"
    [ -n "$deb_block" ] && [ -n "$appimage_block" ] && [ -n "$source_block" ] \
        && [ -n "$flatpak_block" ] && [ -n "$release_block" ] || return 1

    for block in "$deb_block" "$appimage_block" "$source_block" "$flatpak_block"; do
        grep -Fq 'uses: https://git.dinox.im/dinoxim/upload-artifact@v4' <<< "$block" \
            && grep -Fq 'if-no-files-found: error' <<< "$block" \
            && grep -Fq 'retention-days: 7' <<< "$block" || return 1
    done

    grep -Eq '^[[:space:]]+name: dinox-debian-package$' <<< "$deb_block" \
        && [ "$(workflow_artifact_paths <<< "$deb_block")" = $'*.deb\n*.deb.sha256' ] \
        || return 1

    grep -Eq '^[[:space:]]+name: dinox-appimage$' <<< "$appimage_block" \
        && [ "$(workflow_artifact_paths <<< "$appimage_block")" = \
            $'*.AppImage\n*.AppImage.sha256' ] || return 1

    grep -Eq '^[[:space:]]+name: dinox-appimage-corresponding-sources$' <<< "$source_block" \
        && [ "$(workflow_artifact_paths <<< "$source_block")" = \
            $'*.AppImage.sources.tar.xz\n*.AppImage.sources.tar.xz.sha256' ] || return 1

    grep -Eq '^[[:space:]]+name: dinox-flatpak-x86_64$' <<< "$flatpak_block" \
        && [ "$(workflow_artifact_paths <<< "$flatpak_block")" = \
            $'im.dinox.dinox.flatpak\nim.dinox.dinox.flatpak.sha256' ] || return 1

    grep -Fq '*.AppImage *.AppImage.sha256' <<< "$release_block" \
        && grep -Fq '*.AppImage.sources.tar.xz *.AppImage.sources.tar.xz.sha256' \
            <<< "$release_block" || return 1

    grep -Fxq '  DINOX_MAX_DEB_ARTIFACT_BYTES: "167772160"' "$workflow" \
        && grep -Fxq '  DINOX_MAX_APPIMAGE_ARTIFACT_BYTES: "268435456"' "$workflow" \
        && grep -Fxq '  DINOX_MAX_FLATPAK_ARTIFACT_BYTES: "536870912"' "$workflow" \
        && [ "$(grep -c '\$DINOX_MAX_DEB_ARTIFACT_BYTES' "$workflow")" -eq 1 ] \
        && [ "$(grep -c '\$DINOX_MAX_APPIMAGE_ARTIFACT_BYTES' "$workflow")" -eq 1 ] \
        && [ "$(grep -c '\$DINOX_MAX_FLATPAK_ARTIFACT_BYTES' "$workflow")" -eq 1 ] \
        || return 1
}

assert_local_build_configuration_gate() {
    local root output
    root="$(mktemp -d)"
    trap 'rm -rf "$root"' RETURN
    mkdir -p "$root/build/meson-info"
    cat > "$root/build/meson-info/intro-buildoptions.json" <<'EOF'
[
  {"name": "plugin-rtp", "value": "enabled"},
  {"name": "plugin-google-webrtc", "value": "disabled"},
  {"name": "google-libwebrtc-wrapper", "value": "disabled"},
  {"name": "google-libwebrtc-runtime-root", "value": ""},
  {"name": "google-libwebrtc-test-oracle", "value": true},
  {"name": "google-libwebrtc-tests", "value": true}
]
EOF

    output="$(
        cd "$root"
        ok_count=0
        warn_count=0
        fail_count=0
        diagnose_local_build_configuration
        printf 'FAIL_COUNT=%s\n' "$fail_count"
    )"

    grep -qF 'Meson plugin-rtp=enabled (erwartet: disabled)' <<< "$output" \
        && grep -qF 'Meson plugin-google-webrtc=disabled (erwartet: enabled)' <<< "$output" \
        && grep -qF 'Meson google-libwebrtc-test-oracle=true (erwartet: false)' <<< "$output" \
        && grep -qF 'Meson google-libwebrtc-tests=true (erwartet: false)' <<< "$output" \
        && grep -qF 'Meson google-libwebrtc-runtime-root fehlt' <<< "$output" \
        && grep -Eq 'FAIL_COUNT=([1-9]|[1-9][0-9]+)$' <<< "$output" \
        || return 1

    # A selected package tree must be read independently of the default build/.
    mv "$root/build" "$root/package build"
    output="$(
        cd "$root"
        fail_count=0
        diagnose_local_build_configuration "package build"
    )"
    grep -qF 'Meson plugin-rtp=enabled (erwartet: disabled)' <<< "$output" || return 1
    if grep -qF 'Meson-Buildoptionen fehlen' <<< "$output"; then
        return 1
    fi
    output="$(
        cd "$root"
        fail_count=0
        diagnose_local_build_configuration "missing package build"
        printf 'FAIL_COUNT=%s\n' "$fail_count"
    )"
    grep -qF 'missing package build/meson-info/intro-buildoptions.json' <<< "$output" \
        && grep -qF 'FAIL_COUNT=1' <<< "$output" || return 1

    rm -rf "$root"
    trap - RETURN
}

run_self_test() {
    section "package-runtime-matrix self-test"
    assert_self_test "appsink Plugin-Mapping" assert_plugin_mapping appsink libgstapp.so
    assert_self_test "Unbekanntes Plugin schlägt fehl" assert_unknown_plugin_fails
    assert_self_test "IBus SONAME-Alias: fehlende Pfade und vorhandene Dateien/Symlinks" assert_ibus_alias_absence_gate
    assert_self_test "Statische GStreamer-Prüfung" assert_static_gst_check
    assert_self_test "AppDir GIO TLS-Modul, Cache und Ladepfad" assert_appdir_gio_tls_gate
    assert_self_test "AppDir GTK Medienmodul und isolierte Modulpfade" assert_appdir_gtk_modules_gate
    assert_self_test "AppDir Desktop-, Sound- und Kryptomodule ohne Host-Pfad" assert_appdir_auxiliary_modules_gate
    assert_self_test "Statische GStreamer-Mappings paketiert" assert_static_gst_mappings_are_packaged
    assert_self_test "Keine alten GStreamer Call-/Recorder-Mappings" assert_legacy_gst_call_and_recorder_mappings_absent
    assert_self_test "Paketierte GStreamer-Plugins eindeutig" assert_packaged_gstreamer_plugins_unique
    assert_self_test "Paketierte GStreamer-Plugins beschriftet" assert_packaged_gstreamer_plugins_have_labels
    assert_self_test "Paketierte GStreamer-Plugins Dateinamen" assert_packaged_gstreamer_plugins_have_filenames
    assert_self_test "Paketierte GStreamer-Plugin-Labels eindeutig" assert_packaged_gstreamer_plugin_labels_unique
    assert_self_test "Produktionsplugin-Inventar fail-closed" assert_production_plugin_inventory_gate
    assert_self_test "Checkout-LINGUAS-Katalogmatrix fail-closed" assert_translation_catalog_inventory_gate
    assert_self_test "Lokale Produktionskonfiguration fail-closed" assert_local_build_configuration_gate
    assert_self_test "Ein sauberer DEB-Build mit strikter Warnungsprüfung" \
        python3 "$PROJECT_ROOT/scripts/test-deb-build-flow.py"
    assert_self_test "Forgejo Zeitlimits für Paketbau und Abschlussprüfungen" \
        python3 "$PROJECT_ROOT/scripts/test-package-workflow-budgets.py"
    assert_self_test "Argumentvalidierung" assert_arg_validation
    assert_self_test "Flatpak Manifest Modul-Optionen" assert_flatpak_manifest_module_config_checks
    assert_self_test "Fehlende Zielpfade/AppDir Pflichtdateien" assert_missing_target_failures
    assert_self_test "Deb Wrapper Pflichtpfade" assert_deb_wrapper_checks
    assert_self_test "AT-SPI Wrapper-/Prüfmuster konsistent" assert_accessibility_wrapper_contract
    assert_self_test "AppDir Desktop Pflichtfelder" assert_appdir_desktop_checks
    assert_self_test "AppDir Desktop-Kopien identisch" assert_appdir_desktop_files_match
    assert_self_test "AppDir .DirIcon Symlink" assert_appdir_diricon_symlink
    assert_self_test "AppDir Icon-Größen" assert_appdir_icon_sizes
    assert_self_test "AppStream Screenshot Assets" assert_appstream_screenshot_assets
    assert_self_test "ffmpeg Capability-Parser" assert_ffmpeg_capability_parser
    assert_self_test "Fehlender ffmpeg-Encoder bricht Matrix nicht ab" assert_ffmpeg_missing_encoder_does_not_abort
    assert_self_test "ffmpeg Copy-Mux erbt kein offenes stdin" assert_ffmpeg_copy_mux_does_not_inherit_stdin
    assert_self_test "GnuPG Versions-Parser" assert_gnupg_version_parser
    assert_self_test "Google/libwebrtc Notice-Inventar" assert_google_notice_inventory
    assert_self_test "ELF Host-ABI-Allowlist" assert_elf_host_abi_allowlist
    assert_self_test "Statische All-ELF Runtime-Closure" assert_static_all_elf_closure
    assert_self_test "Release-verbotene RTP-/WebRTC-Testartefakte" assert_release_forbidden_artifact_gate
    assert_self_test "bot-features/OMEMO ELF-Laufzeitpfade" assert_bot_features_omemo_runtime_paths
    assert_self_test "Google/libwebrtc ELF-Laufzeitpfade" assert_google_webrtc_runtime_paths
    assert_self_test "AppImage Distributionsprovenienz fail-closed" assert_distribution_provenance_gate
    assert_self_test "AppImage Source-Sidecar/Slim-Split fail-closed" assert_appimage_source_split_gate
    assert_self_test "AppImage Offline-Desktop-ABI-Gate fail-closed" assert_appimage_runtime_gate_contract
    assert_self_test "Forgejo Paket-/Source-Artefakte strikt getrennt" assert_package_artifact_split_contract
}

diagnose_gstreamer() {
    section "GStreamer Demux/Decode/Wiedergabe/Metadaten"
    if ! live_gstreamer_diagnostics_allowed; then
        row_info "Live GStreamer-Prüfung in CI absichtlich deaktiviert; statische Paketprüfungen aktiv"
        return
    fi
    if [ "$GST_CHECK_MODE" != "static" ] && ! have_cmd gst-inspect-1.0; then
        row_fail "gst-inspect-1.0 fehlt; Paket gstreamer1.0-tools installieren"
        return
    fi

    check_gst_element playbin
    check_gst_element uridecodebin
    check_gst_element decodebin
    check_gst_element typefind
    check_gst_element queue
    check_gst_element filesrc
    check_gst_element fakesink
    check_gst_element capsfilter

    section "GStreamer Audio-Wiedergabe und Metadaten"
    check_gst_element audioconvert
    check_gst_element audioresample
    check_gst_element level
    check_gst_element volume "Software-Lautstärke für playbin"
    check_gst_element aacparse
    check_gst_element avdec_aac "AAC-Decoder"
    check_gst_element opusdec "Opus-Decoder"
    check_gst_element vorbisdec "Vorbis-Decoder"
    check_gst_element giostreamsrc "GIO-Ressourcenquelle für Notification-Sound"
    check_gst_element wavparse "WAV-Parser für Notification-Sound"
    check_gst_element oggdemux "Ogg-Demuxer"
    check_gst_element autoaudiosink "Automatische Audioausgabe für Notification-Sound"
    check_gst_any "Audioausgabe für Notification-Sound" pulsesink alsasink pipewiresink

    section "GStreamer Video-Wiedergabe, Vorschau und Metadaten"
    check_gst_element videoconvert
    check_gst_any "H.264-Decoder" avdec_h264 openh264dec
    check_gst_element h264parse
    check_gst_element qtdemux
    check_gst_element matroskademux
    check_gst_element vp8dec "VP8-Decoder"
    check_gst_element vp9dec "VP9-Decoder"

    section "GStreamer appsink-Bridge zu Google/libwebrtc"
    check_gst_element appsink
}

setup_appdir_env() {
    local appdir="$1"
    # AppDir checks are intentionally static.  Running gst-inspect here can
    # spawn gst-plugin-scanner inside Forgejo/DIND; if scanner blocks in
    # uninterruptible sleep, timeout cannot clean it up and the server load
    # stays high until reboot.
    GST_CHECK_MODE="static"
    GST_STATIC_PLUGIN_DIR="$appdir/usr/lib/gstreamer-1.0"
}

appdir_library_path() {
    local appdir="$1" path="$appdir/usr/lib/dinox:$appdir/usr/lib"
    local directory
    shopt -s nullglob
    for directory in "$appdir"/usr/lib/*-linux-gnu; do
        [ -d "$directory" ] && path="$path:$directory"
    done
    shopt -u nullglob
    printf '%s\n' "$path"
}

run_appdir_gnupg_command() {
    local appdir="$1" gnupg_home="$2" library_path="$3"
    shift 3
    local -a command=( "$@" )
    local -a environment=(
        env -u GPG_AGENT_INFO
        "APPDIR=$appdir"
        "APPIMAGE=$appdir/DinoX-runtime-matrix.AppImage"
        "HOME=$(dirname "$gnupg_home")"
        "GNUPGHOME=$gnupg_home"
        "PATH=$appdir/usr/bin:/usr/bin:/bin"
        "LD_LIBRARY_PATH=$library_path"
        LC_ALL=C
    )
    if have_cmd timeout; then
        timeout --kill-after=2s 8s "${environment[@]}" "${command[@]}"
    else
        "${environment[@]}" "${command[@]}"
    fi
}

check_appdir_system_component_provenance() {
    local appdir="$1" package="$2" source_package="$3" label="$4"
    local inventory="$appdir/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv"

    if [ -s "$inventory" ] \
            && awk -F '\t' -v package="$package" -v source="$source_package" \
                '$3 ~ ("^" package ":[^:]+$") && $6 == source { found = 1 } END { exit(found ? 0 : 1) }' \
                "$inventory"; then
        row_ok "$label Paketprovenienz ($package aus $source_package)"
    else
        row_fail "$label Paketprovenienz fehlt ($package aus $source_package)"
    fi
    check_file \
        "$appdir/usr/share/licenses/dinox/system-packages/$package/copyright" \
        "$label Debian-Copyright"
}

validate_appdir_runtime_provenance() {
    local appdir="$1"
    local license_root="${2:-$appdir/usr/share/licenses/dinox}"
    local inventory="$appdir/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv"
    local expected_header package_path host_path binary_package binary_version architecture
    local source_package source_version packaged_sha host_source_sha transform copyright_path extra actual_sha owner_base
    local canonical_appdir canonical_target

    expected_header=$'package_path\thost_source_path\tbinary_package\tbinary_version\tarchitecture\tsource_package\tsource_version\tpackaged_sha256\thost_source_sha256\ttransform\tcopyright_path'
    [ -s "$inventory" ] || return 1
    [ "$(head -1 "$inventory")" = "$expected_header" ] || return 1
    [ "$(wc -l < "$inventory")" -gt 1 ] || return 1
    [ -d "$license_root/system-packages" ] || return 1
    canonical_appdir="$(readlink -f -- "$appdir" 2>/dev/null || true)"
    [ -n "$canonical_appdir" ] && [ -d "$canonical_appdir" ] || return 1

    while IFS=$'\t' read -r package_path host_path binary_package binary_version \
            architecture source_package source_version packaged_sha host_source_sha transform \
            copyright_path extra; do
        [ -z "${extra:-}" ] || return 1
        [ -n "$package_path" ] && [ -n "$host_path" ] && [ -n "$binary_package" ] \
            && [ -n "$binary_version" ] && [ -n "$architecture" ] \
            && [ -n "$source_package" ] && [ -n "$source_version" ] \
            && [[ "$packaged_sha" =~ ^[0-9a-f]{64}$ ]] \
            && [[ "$host_source_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
        case "$package_path" in /*|../*|*/../*|*/..|.|..) return 1 ;; esac
        case "$host_path" in /*) ;; *) return 1 ;; esac
        case "$binary_package" in *:"$architecture") ;; *) return 1 ;; esac
        [ -e "$appdir/$package_path" ] || return 1
        canonical_target="$(readlink -f -- "$appdir/$package_path" 2>/dev/null || true)"
        case "$canonical_target" in
            "$canonical_appdir"/*) ;;
            *) return 1 ;;
        esac
        actual_sha="$(sha256sum "$appdir/$package_path" | awk '{ print $1 }')"
        [ "$actual_sha" = "$packaged_sha" ] || return 1
        case "$transform" in
            verbatim-copy) [ "$packaged_sha" = "$host_source_sha" ] || return 1 ;;
            post-copy-modified) [ "$packaged_sha" != "$host_source_sha" ] || return 1 ;;
            *) return 1 ;;
        esac
        owner_base="${binary_package%%:*}"
        [ "$copyright_path" = "/usr/share/doc/$owner_base/copyright" ] || return 1
        [ -s "$license_root/system-packages/$owner_base/copyright" ] \
            || return 1
    done < <(tail -n +2 "$inventory")
}

validate_appdir_distribution_provenance() {
    local appdir="$1"
    local license_root="${2:-$appdir/usr/share/licenses/dinox}"
    local inventory="$appdir/usr/share/licenses/dinox/SYSTEM_COMPONENTS.tsv"
    local source_inventory="$license_root/SYSTEM_COMPONENTS.tsv"
    local source_base="$license_root/corresponding-sources/distribution"
    local source_root metadata checksums listed_files actual_files expected_files dsc dsc_source dsc_version
    local pairs expected_packages actual_packages extract_root

    validate_appdir_runtime_provenance "$appdir" "$license_root" || return 1
    [ -s "$source_inventory" ] && cmp -s "$inventory" "$source_inventory" || return 1
    [ -d "$source_base" ] || return 1

    pairs="$(mktemp)"
    tail -n +2 "$inventory" | cut -f6,7 | sort -u > "$pairs"
    if ! awk -F '\t' 'seen[$1] && seen[$1] != $2 { exit 1 } { seen[$1] = $2 }' "$pairs"; then
        rm -f "$pairs"
        return 1
    fi

    expected_packages="$(cut -f1 "$pairs" | sort -u)"
    actual_packages="$(find "$source_base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -u)"
    [ "$expected_packages" = "$actual_packages" ] || { rm -f "$pairs"; return 1; }

    while IFS=$'\t' read -r source_package source_version; do
        source_root="$source_base/$source_package"
        metadata="$source_root/METADATA"
        checksums="$source_root/SHA256SUMS"
        [ -s "$metadata" ] && [ -s "$checksums" ] || { rm -f "$pairs"; return 1; }
        grep -Fx "source_package=$source_package" "$metadata" >/dev/null \
            || { rm -f "$pairs"; return 1; }
        grep -Fx "source_version=$source_version" "$metadata" >/dev/null \
            || { rm -f "$pairs"; return 1; }
        grep -Fx 'source_format=debian-source-package' "$metadata" >/dev/null \
            || { rm -f "$pairs"; return 1; }
        expected_packages="$(awk -F '\t' -v source="$source_package" -v version="$source_version" \
            '$6 == source && $7 == version { print $3 }' "$inventory" | sort -u | paste -sd, -)"
        grep -Fx "binary_packages=$expected_packages" "$metadata" >/dev/null \
            || { rm -f "$pairs"; return 1; }

        listed_files="$(awk '{ name = $2; sub(/^\*/, "", name); print name }' "$checksums" | sort -u)"
        actual_files="$(find "$source_root" -maxdepth 1 -type f \
            ! -name METADATA ! -name SHA256SUMS -printf '%f\n' | sort -u)"
        [ -n "$actual_files" ] && [ "$listed_files" = "$actual_files" ] \
            || { rm -f "$pairs"; return 1; }
        (cd "$source_root" && sha256sum -c SHA256SUMS >/dev/null 2>&1) \
            || { rm -f "$pairs"; return 1; }
        [ "$(find "$source_root" -maxdepth 1 -type f -name '*.dsc' | wc -l)" -eq 1 ] \
            || { rm -f "$pairs"; return 1; }
        dsc="$(find "$source_root" -maxdepth 1 -type f -name '*.dsc' -print -quit)"
        dsc_source="$(sed -n 's/^Source:[[:space:]]*//p' "$dsc" | tail -1)"
        dsc_version="$(sed -n 's/^Version:[[:space:]]*//p' "$dsc" | tail -1)"
        [ "$dsc_source" = "$source_package" ] && [ "$dsc_version" = "$source_version" ] \
            || { rm -f "$pairs"; return 1; }
        expected_files="$({
            basename "$dsc"
            awk '
                /^Checksums-Sha256:/ { in_checksums = 1; next }
                in_checksums && /^ / { print $3; next }
                in_checksums { exit }
            ' "$dsc"
        } | sort -u)"
        [ "$expected_files" = "$actual_files" ] \
            || { rm -f "$pairs"; return 1; }
        [ "$(find "$source_root" -maxdepth 1 -type f \
            \( -name '*.tar.gz' -o -name '*.tar.bz2' -o -name '*.tar.lzma' -o -name '*.tar.xz' -o -name '*.tar.zst' \) \
            | wc -l)" -ge 1 ] \
            || { rm -f "$pairs"; return 1; }
        (cd "$source_root" && awk '
            /^Checksums-Sha256:/ { in_checksums = 1; next }
            in_checksums && /^ / { print $1 "  " $3; found = 1; next }
            in_checksums { exit }
            END { if (!found) exit 1 }
        ' "$(basename "$dsc")" | sha256sum -c - >/dev/null 2>&1) \
            || { rm -f "$pairs"; return 1; }
        command -v dpkg-source >/dev/null 2>&1 \
            || { rm -f "$pairs"; return 1; }
        extract_root="$(mktemp -d)"
        if ! dpkg-source --no-check -x "$dsc" "$extract_root/source" >/dev/null 2>&1 \
                || [ ! -d "$extract_root/source" ]; then
            rm -rf "$extract_root"
            rm -f "$pairs"
            return 1
        fi
        rm -rf "$extract_root"
    done < "$pairs"
    rm -f "$pairs"
}

check_appdir_distribution_provenance() {
    local appdir="$1"
    local license_root="${2:-$appdir/usr/share/licenses/dinox}"
    if validate_appdir_distribution_provenance "$appdir" "$license_root"; then
        row_ok "AppImage dateibezogene Debian-Provenienz und exakte Quellpakete vollständig"
    else
        row_fail "AppImage dateibezogene Debian-Provenienz oder exakte Quellpakete unvollständig"
    fi
}

check_appdir_runtime_provenance() {
    local appdir="$1"
    if validate_appdir_runtime_provenance "$appdir"; then
        row_ok "AppImage dateibezogenes Laufzeit-/Lizenzinventar vollständig"
    else
        row_fail "AppImage dateibezogenes Laufzeit-/Lizenzinventar unvollständig"
    fi
}

safe_source_relative_path() {
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

file_is_world_readable() {
    local path="$1"
    local mode

    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    mode="$(stat -c '%a' -- "$path" 2>/dev/null || true)"
    case "${mode: -1}" in
        4|5|6|7) return 0 ;;
        *) return 1 ;;
    esac
}

is_appimage_source_payload_path() {
    local relative="$1"

    safe_source_relative_path "$relative" || return 1
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

    [ -d "$license_root/corresponding-sources" ] || return 1
    [ -d "$license_root/google-libwebrtc/sources" ] || return 1
    if find \
            "$license_root/corresponding-sources" \
            "$license_root/google-libwebrtc/sources" \
            -type l -print -quit 2>/dev/null | grep . >/dev/null; then
        return 1
    fi
    while IFS= read -r -d '' path; do
        relative="${path#"$license_root"/}"
        is_appimage_source_payload_path "$relative" || return 1
        printf '%s\n' "$relative"
    done < <(
        find "$license_root/corresponding-sources" -type f \
            ! -name METADATA ! -name SHA256SUMS -print0
        find "$license_root/google-libwebrtc/sources" -type f -print0
    ) | LC_ALL=C sort -u
}

validate_appimage_source_payload_inventory() {
    local license_root="$1"
    local layout="$2"
    local payloads="$license_root/SOURCE_PAYLOADS.tsv"
    local relative size checksum extra actual_size actual_checksum previous=""
    local expected_paths actual_paths
    local LC_ALL=C

    [ "$layout" = "full" ] || [ "$layout" = "slim" ] || return 1
    [ -s "$payloads" ] || return 1
    file_is_world_readable "$payloads" || return 1
    [ "$(head -1 "$payloads")" = $'relative_path\tsize\tsha256' ] || return 1
    [ "$(wc -l < "$payloads")" -gt 1 ] || return 1

    expected_paths="$(mktemp)"
    while IFS=$'\t' read -r relative size checksum extra; do
        [ -n "$relative" ] && [ -z "${extra:-}" ] \
            && is_appimage_source_payload_path "$relative" || {
                rm -f "$expected_paths"
                return 1
            }
        [[ "$size" =~ ^[1-9][0-9]*$ ]] && [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || {
            rm -f "$expected_paths"
            return 1
        }
        if [ -n "$previous" ] && [[ "$relative" < "$previous" || "$relative" = "$previous" ]]; then
            rm -f "$expected_paths"
            return 1
        fi
        previous="$relative"
        printf '%s\n' "$relative" >> "$expected_paths"

        if [ "$layout" = "full" ]; then
            [ -f "$license_root/$relative" ] && [ ! -L "$license_root/$relative" ] || {
                rm -f "$expected_paths"
                return 1
            }
            actual_size="$(stat -c '%s' -- "$license_root/$relative" 2>/dev/null || true)"
            actual_checksum="$(sha256sum -- "$license_root/$relative" 2>/dev/null | awk '{ print $1 }')"
            [ "$actual_size" = "$size" ] && [ "$actual_checksum" = "$checksum" ] || {
                rm -f "$expected_paths"
                return 1
            }
        elif [ -e "$license_root/$relative" ] || [ -L "$license_root/$relative" ]; then
            rm -f "$expected_paths"
            return 1
        fi
    done < <(tail -n +2 "$payloads")

    actual_paths="$(mktemp)"
    if ! list_appimage_source_payloads "$license_root" > "$actual_paths"; then
        rm -f "$expected_paths" "$actual_paths"
        return 1
    fi
    if [ "$layout" = "full" ]; then
        cmp -s "$expected_paths" "$actual_paths" || {
            rm -f "$expected_paths" "$actual_paths"
            return 1
        }
    elif [ -s "$actual_paths" ]; then
        rm -f "$expected_paths" "$actual_paths"
        return 1
    fi
    rm -f "$expected_paths" "$actual_paths"
}

write_non_payload_license_manifest() {
    local license_root="$1"
    local output="$2"
    local path relative size checksum type

    [ -d "$license_root" ] || return 1
    if find "$license_root" \( -type l -o ! -type d ! -type f \) -print -quit \
            2>/dev/null | grep . >/dev/null; then
        return 1
    fi
    : > "$output"
    while IFS= read -r -d '' path; do
        relative="${path#"$license_root"/}"
        safe_source_relative_path "$relative" || return 1
        if [ -d "$path" ]; then
            printf 'd\t%s\n' "$relative" >> "$output"
            continue
        fi
        is_appimage_source_payload_path "$relative" && continue
        [ "$relative" = "SOURCE_BUNDLE.sha256" ] && continue
        size="$(stat -c '%s' -- "$path" 2>/dev/null || true)"
        checksum="$(sha256sum -- "$path" 2>/dev/null | awk '{ print $1 }')"
        [[ "$size" =~ ^[0-9]+$ ]] && [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] \
            || return 1
        type="f"
        printf '%s\t%s\t%s\t%s\n' "$type" "$relative" "$size" "$checksum" >> "$output"
    done < <(find "$license_root" -mindepth 1 \( -type d -o -type f \) -print0 | sort -z)
}

validate_appdir_source_sidecar_provenance() {
    local appdir="$1"
    local extracted_license_root="$2"
    local appdir_license_root="$appdir/usr/share/licenses/dinox"
    local appdir_manifest extracted_manifest
    local canonical_appdir canonical_extracted

    canonical_appdir="$(readlink -f -- "$appdir_license_root" 2>/dev/null || true)"
    canonical_extracted="$(readlink -f -- "$extracted_license_root" 2>/dev/null || true)"
    [ -n "$canonical_appdir" ] && [ -d "$canonical_appdir" ] \
        && [ -n "$canonical_extracted" ] && [ -d "$canonical_extracted" ] \
        && [ "$canonical_appdir" != "$canonical_extracted" ] || return 1
    [ ! -e "$extracted_license_root/SOURCE_BUNDLE.sha256" ] \
        && [ ! -L "$extracted_license_root/SOURCE_BUNDLE.sha256" ] || return 1
    file_is_world_readable "$extracted_license_root/SOURCE_OFFER.md" || return 1

    validate_slim_appdir_source_offer "$appdir" || return 1
    validate_appimage_source_payload_inventory "$extracted_license_root" full || return 1
    cmp -s \
        "$appdir_license_root/SOURCE_PAYLOADS.tsv" \
        "$extracted_license_root/SOURCE_PAYLOADS.tsv" || return 1
    cmp -s \
        "$appdir_license_root/SOURCE_OFFER.md" \
        "$extracted_license_root/SOURCE_OFFER.md" || return 1

    appdir_manifest="$(mktemp)"
    extracted_manifest="$(mktemp)"
    if ! write_non_payload_license_manifest "$appdir_license_root" "$appdir_manifest" \
            || ! write_non_payload_license_manifest "$extracted_license_root" "$extracted_manifest" \
            || ! cmp -s "$appdir_manifest" "$extracted_manifest"; then
        rm -f "$appdir_manifest" "$extracted_manifest"
        return 1
    fi
    rm -f "$appdir_manifest" "$extracted_manifest"
}

validate_slim_appdir_source_offer() {
    local appdir="$1"
    local license_root="$appdir/usr/share/licenses/dinox"
    local payloads="$license_root/SOURCE_PAYLOADS.tsv"
    local offer="$license_root/SOURCE_OFFER.md"
    local bundle_checksum="$license_root/SOURCE_BUNDLE.sha256"
    local source_bundle checksum_name checksum_hash extra

    [ -s "$payloads" ] && [ -s "$offer" ] && [ -s "$bundle_checksum" ] || return 1
    file_is_world_readable "$offer" && file_is_world_readable "$bundle_checksum" || return 1
    validate_appimage_source_payload_inventory "$license_root" slim || return 1

    source_bundle="$(sed -n 's/^source_bundle=//p' "$offer")"
    [ "$(grep -c '^source_bundle=' "$offer")" -eq 1 ] \
        && [ -n "$source_bundle" ] \
        && safe_source_relative_path "$source_bundle" \
        && [ "$(basename -- "$source_bundle")" = "$source_bundle" ] \
        || return 1
    [ "$(grep -c '^payload_inventory=' "$offer")" -eq 1 ] \
        && grep -Fx 'payload_inventory=SOURCE_PAYLOADS.tsv' "$offer" >/dev/null \
        || return 1
    [ "$(grep -c '^bundle_checksum=' "$offer")" -eq 1 ] \
        && grep -Fx 'bundle_checksum=SOURCE_BUNDLE.sha256' "$offer" >/dev/null \
        || return 1
    [ "$(wc -l < "$bundle_checksum")" -eq 1 ] || return 1
    read -r checksum_hash checksum_name extra < "$bundle_checksum" || return 1
    [[ "$checksum_hash" =~ ^[0-9a-f]{64}$ ]] \
        && [ "$checksum_name" = "$source_bundle" ] && [ -z "${extra:-}" ] || return 1
}

check_slim_appdir_source_offer() {
    local appdir="$1"
    if validate_slim_appdir_source_offer "$appdir"; then
        row_ok "AppImage schlankes Source-Angebot und Payload-Abwesenheit vollständig"
    else
        row_fail "AppImage Source-Angebot fehlt, ist inkonsistent oder enthält noch Quellpayloads"
    fi
}

check_ibus_compat_package() {
    local prefix="$1"
    local licenses="$2"
    local library="$prefix/lib/dinox/ibus-compat/libibus-1.0.so.5.0.530"
    local metadata="$prefix/lib/dinox/ibus-compat/METADATA"
    local copying="$licenses/custom-dependencies/ibus-compat/files/COPYING"
    local sources="$licenses/corresponding-sources/ibus-compat"
    local expected_library_sha

    if bash "$SCRIPT_DIR/prepare-ibus-compat.sh" --check-library "$library" >/dev/null 2>&1; then
        row_ok "Private IBus 1.5.30 ELF/SONAME/Architektur"
    else
        row_fail "Private IBus 1.5.30 ELF/SONAME/Architektur ungültig"
    fi
    check_file_contains "$metadata" "checksum=$IBUS_COMPAT_SOURCE_SHA256" "IBus Runtime-Quellpin"
    expected_library_sha="$(sed -n 's/^library_sha256=//p' "$metadata" 2>/dev/null || true)"
    if [[ "$expected_library_sha" =~ ^[0-9a-f]{64}$ ]]; then
        check_file_sha256 "$library" "$expected_library_sha" "IBus gebauter Payload unverändert"
    else
        row_fail "IBus Runtime-Payload-Prüfsumme fehlt"
    fi
    check_file "$copying" "IBus LGPL-Lizenztext"
    check_file_sha256 "$copying" \
        "5df07007198989c622f5d41de8d703e7bef3d0e79d62e24332ee739a452af62a" "IBus Lizenztext-Prüfsumme"
    check_file_contains "$sources/METADATA" "checksum=$IBUS_COMPAT_SOURCE_SHA256" "IBus Quellmetadaten"
    check_file_contains "$sources/METADATA" "license_expression=LGPL-2.1-or-later" "IBus LGPL-Lizenzmetadaten"
    check_glob_absent "$prefix/lib/dinox/ibus-compat/libibus-1.0.so.5" "IBus Fallback ohne SONAME-Alias"
}

check_ibus_compat_source_recipe() {
    local prefix="$1"
    local licenses="$2"
    local recipe="$licenses/corresponding-sources/ibus-compat/prepare-ibus-compat.sh"
    local expected_sha
    check_file "$recipe" "IBus exaktes Buildrezept"
    expected_sha="$(sed -n 's/^recipe_sha256=//p' "$prefix/lib/dinox/ibus-compat/METADATA" 2>/dev/null || true)"
    if [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
        check_file_sha256 "$recipe" "$expected_sha" "IBus Buildrezept-Prüfsumme"
    else
        row_fail "IBus Buildrezept-Prüfsumme fehlt"
    fi
}

diagnose_appdir_source_provenance() {
    local appdir="$1"
    local license_root="$2"
    local recorder_ffmpeg_metadata="$license_root/corresponding-sources/recorder-ffmpeg/METADATA"
    local recorder_x264_metadata="$license_root/corresponding-sources/recorder-x264/METADATA"
    local recorder_ffmpeg_source="$license_root/corresponding-sources/recorder-ffmpeg/ffmpeg-$FFMPEG_RECORDER_VERSION.tar.xz"
    local recorder_x264_source="$license_root/corresponding-sources/recorder-x264/x264-$X264_RECORDER_COMMIT.tar.gz"

    section "AppImage vollständige Source-Sidecar-Provenienz"
    check_ibus_compat_source_recipe "$appdir/usr" "$license_root"
    check_file "$license_root/corresponding-sources/ibus-compat/ibus_1.5.30.orig.tar.gz" \
        "IBus exaktes Quellarchiv"
    check_file_sha256 "$license_root/corresponding-sources/ibus-compat/ibus_1.5.30.orig.tar.gz" \
        "$IBUS_COMPAT_SOURCE_SHA256" "IBus exakter Quellstand"
    check_file "$license_root/google-libwebrtc/sources/ffmpeg-8.1.2.tar.xz" \
        "Google/libwebrtc FFmpeg-Quellarchiv"
    check_file_sha256 \
        "$license_root/google-libwebrtc/sources/ffmpeg-8.1.2.tar.xz" \
        "$FFMPEG_RECORDER_SHA256" "Google/libwebrtc FFmpeg exakter Quellstand"
    check_file "$license_root/google-libwebrtc/sources/libva-2.20.0.tar.gz" \
        "Google/libwebrtc libva-Quellarchiv"
    check_file_sha256 \
        "$license_root/google-libwebrtc/sources/libva-2.20.0.tar.gz" \
        "$LIBVA_SOURCE_SHA256" "Google/libwebrtc libva exakter Quellstand"
    check_file_sha256 \
        "$license_root/google-libwebrtc/sources/nv-codec-headers-n8.1.24.15.tar.gz" \
        '1e1600606cde2c04f5b1a71cb3b2e966b3ffe4e252a6ddec5781151d982e259f' \
        "Google/libwebrtc NVIDIA exakte Headerquellen"
    check_file_sha256 \
        "$license_root/google-libwebrtc/sources/ffmpeg-dinox-symbol-versions.patch" \
        'e3630fac46c8459340de0b1eb58916f1f3dada03899bded00bca332486375903' \
        "Google/libwebrtc privater FFmpeg-Symbolpatch"
    check_file_sha256 \
        "$license_root/google-libwebrtc/sources/webrtc-m152-codec-sources-6f37672d3584-sha256-2b17c14cc13b.tar.gz" \
        '2b17c14cc13b4b661c4a2be9b25c26240c97cec4a1c938196ed81dc9fd24278c' \
        "Google/libwebrtc M152 exakte Codecquellen"
    check_file "$recorder_ffmpeg_source" "Recorder-FFmpeg Quellarchiv"
    check_file_sha256 "$recorder_ffmpeg_source" "$FFMPEG_RECORDER_SHA256" \
        "Recorder-FFmpeg Quellarchiv-Prüfsumme"
    check_file "$recorder_x264_source" "Recorder-x264 Quellarchiv"
    check_file_sha256 "$recorder_x264_source" "$X264_RECORDER_SHA256" \
        "Recorder-x264 Quellarchiv-Prüfsumme"
    check_file_contains "$recorder_ffmpeg_metadata" \
        "checksum=$FFMPEG_RECORDER_SHA256" "Recorder-FFmpeg Quellmetadaten"
    check_file_contains "$recorder_x264_metadata" \
        "checksum=$X264_RECORDER_SHA256" "Recorder-x264 Quellmetadaten"
    check_appdir_distribution_provenance "$appdir" "$license_root"
}

diagnose_appdir_source_sidecar_provenance() {
    local appdir="$1"
    local extracted_license_root="$2"

    diagnose_appdir_source_provenance "$appdir" "$extracted_license_root"
    if validate_appdir_source_sidecar_provenance "$appdir" "$extracted_license_root"; then
        row_ok "AppImage Source-Sidecar entspricht exakt Inventar und schlankem AppDir"
    else
        row_fail "AppImage Source-Sidecar weicht von Inventar oder schlankem AppDir ab"
    fi
}

diagnose_appdir_gnupg_runtime() {
    local appdir="$1"
    local library_path tmp_dir gnupg_home binary output version
    local dirs components
    local launch_agent_ok=0 launch_dirmngr_ok=0 kill_ok=0
    local -a binaries=(gpg gpgconf gpg-agent dirmngr gpg-connect-agent)

    section "AppDir OpenPGP GnuPG 2.4 Runtime"
    library_path="$(appdir_library_path "$appdir")"
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dinox-gnupg-matrix.XXXXXX")"
    gnupg_home="$tmp_dir/gnupg"
    mkdir -m 0700 "$gnupg_home"

    for binary in "${binaries[@]}"; do
        if output="$(run_appdir_gnupg_command "$appdir" "$gnupg_home" "$library_path" \
                "$appdir/usr/bin/$binary" --version 2>&1)"; then
            version="$(printf '%s\n' "$output" | gnupg_version_from_output)"
            case "$version" in
                "$GNUPG_REQUIRED_SERIES".*) row_ok "$binary GnuPG $version isoliert ausführbar" ;;
                *) row_fail "$binary meldet falsche GnuPG-Version: ${version:-unbekannt}" ;;
            esac
        else
            row_fail "$binary --version im AppDir fehlgeschlagen"
        fi
    done

    if output="$(run_appdir_gnupg_command "$appdir" "$gnupg_home" "$library_path" \
            "$appdir/usr/bin/curl" --version 2>&1)" \
            && grep -Eq '^curl [0-9]' <<< "$output"; then
        row_ok "OpenPGP curl isoliert ausführbar"
    else
        row_fail "OpenPGP curl --version im AppDir fehlgeschlagen"
    fi

    dirs="$(run_appdir_gnupg_command "$appdir" "$gnupg_home" "$library_path" \
        "$appdir/usr/bin/gpgconf" --homedir "$gnupg_home" --list-dirs 2>/dev/null || true)"
    if grep -Fx "bindir:$appdir/usr/bin" <<< "$dirs" >/dev/null \
            && grep -Fx "sysconfdir:$appdir/usr/etc/gnupg" <<< "$dirs" >/dev/null \
            && grep -Fx "datadir:$appdir/usr/share/gnupg" <<< "$dirs" >/dev/null \
            && grep -Fx "homedir:$gnupg_home" <<< "$dirs" >/dev/null; then
        row_ok "gpgconf verwendet ausschließlich relocatable AppDir-Pfade"
    else
        row_fail "gpgconf AppDir-Pfade sind nicht korrekt relociert"
        sed 's/^/    /' <<< "$dirs"
    fi

    components="$(run_appdir_gnupg_command "$appdir" "$gnupg_home" "$library_path" \
        "$appdir/usr/bin/gpgconf" --homedir "$gnupg_home" --list-components 2>/dev/null || true)"
    if grep -Fx "gpg:OpenPGP:$appdir/usr/bin/gpg" <<< "$components" >/dev/null \
            && grep -Fx "gpg-agent:Private Keys:$appdir/usr/bin/gpg-agent" <<< "$components" >/dev/null \
            && grep -Fx "dirmngr:Network:$appdir/usr/bin/dirmngr" <<< "$components" >/dev/null; then
        row_ok "gpgconf löst GPG, Agent und dirmngr aus dem AppDir auf"
    else
        row_fail "gpgconf löst erforderliche Helfer nicht aus dem AppDir auf"
        sed 's/^/    /' <<< "$components"
    fi

    run_appdir_gnupg_command "$appdir" "$gnupg_home" "$library_path" \
        "$appdir/usr/bin/gpgconf" --homedir "$gnupg_home" --launch gpg-agent \
        >/dev/null 2>&1 && launch_agent_ok=1
    run_appdir_gnupg_command "$appdir" "$gnupg_home" "$library_path" \
        "$appdir/usr/bin/gpgconf" --homedir "$gnupg_home" --launch dirmngr \
        >/dev/null 2>&1 && launch_dirmngr_ok=1
    run_appdir_gnupg_command "$appdir" "$gnupg_home" "$library_path" \
        "$appdir/usr/bin/gpgconf" --homedir "$gnupg_home" --kill all \
        >/dev/null 2>&1 && kill_ok=1
    if [ "$launch_agent_ok" -eq 1 ] && [ "$launch_dirmngr_ok" -eq 1 ] && [ "$kill_ok" -eq 1 ]; then
        row_ok "gpgconf startet und beendet isolierte AppDir-Helfer"
    else
        row_fail "gpgconf Helper-Smoke fehlgeschlagen (agent=$launch_agent_ok dirmngr=$launch_dirmngr_ok kill=$kill_ok)"
    fi

    rm -rf "$tmp_dir"
}

diagnose_appdir_files() {
    local appdir="$1"
    local source_layout="${2:-slim}"
    section "AppDir Dateien"
    check_release_forbidden_artifacts \
        "$appdir" "AppDir Release-Artefakt-Inventar"
    check_file "$appdir/AppRun" "AppRun"
    check_appdir_gio_tls "$appdir"
    check_appdir_gtk_modules "$appdir"
    check_appdir_auxiliary_modules "$appdir"
    check_single_library_payload "$appdir" 'libcanberra.so*' "AppDir private libcanberra"
    check_file_contains "$appdir/AppRun" 'export GSETTINGS_SCHEMA_DIR="${APPDIR}/usr/share/glib-2.0/schemas"' "AppRun GLib Schemapfad"
    check_nonempty_file "$appdir/usr/share/licenses/dinox/custom-dependencies/canberra-runtime/files/COPYING" "libcanberra LGPL-Lizenztext"
    check_file_contains "$appdir/AppRun" 'LD_LIBRARY_PATH="${APPDIR}/usr/lib/dinox:' "AppRun private Bibliothekspfade"
    check_file_contains "$appdir/AppRun" 'GST_PLUGIN_PATH="${APPDIR}/usr/lib/gstreamer-1.0"' "AppRun GStreamer Pluginpfad"
    check_file_contains "$appdir/AppRun" 'GST_PLUGIN_SYSTEM_PATH="${APPDIR}/usr/lib/gstreamer-1.0"' "AppRun GStreamer Systempfad"
    check_file_contains "$appdir/AppRun" 'GST_PLUGIN_PATH_1_0="$GST_PLUGIN_PATH"' "AppRun GStreamer 1.0 Pluginpfad"
    check_file_contains "$appdir/AppRun" 'GST_PLUGIN_SYSTEM_PATH_1_0="$GST_PLUGIN_SYSTEM_PATH"' "AppRun GStreamer 1.0 Systempfad"
    if find "$appdir/usr/lib/gstreamer-1.0" -maxdepth 1 -type f \( -name 'libgstvaapi.so' -o -name 'libgstva.so' \) 2>/dev/null | grep . >/dev/null; then
        row_fail "AppDir VA GStreamer Plugins nicht gebündelt"
    else
        row_ok "AppDir VA GStreamer Plugins nicht gebündelt"
    fi
    check_file_contains "$appdir/AppRun" 'DINO_PLUGIN_DIR="${APPDIR}/usr/lib/' "AppRun Dino Pluginpfad"
    check_file_contains "$appdir/AppRun" 'TEXTDOMAINDIR="${APPDIR}/usr/share/locale"' "AppRun Übersetzungspfad"
    check_file_contains "$appdir/AppRun" 'DINOX_TOR_PATH="${APPDIR}/usr/bin/tor"' "AppRun Tor-Pfad"
    check_file_contains "$appdir/AppRun" 'DINOX_TOR_DATA_DIR="${APPDIR}/usr/share/dinox/tor"' "AppRun Tor-Datenpfad"
    check_file_contains "$appdir/AppRun" 'DINOX_LYREBIRD_PATH="${APPDIR}/usr/bin/lyrebird"' "AppRun Lyrebird-Pfad"
    check_file_contains "$appdir/AppRun" 'PATH="${APPDIR}/usr/bin:' "AppRun ffmpeg-Pfad"
    check_file_contains "$appdir/AppRun" 'XDG_DATA_DIRS="${APPDIR}/usr/share' "AppRun XDG Datenpfad"
    check_file_contains "$appdir/AppRun" 'GSETTINGS_SCHEMA_DIR="${APPDIR}/usr/share/glib-2.0/schemas' "AppRun GSettings Schemapfad"
    check_file_contains "$appdir/AppRun" 'SSL_CERT_FILE="$GTLS_SYSTEM_CA_FILE"' "AppRun OpenPGP curl CA-Pfad"
    check_file_contains "$appdir/AppRun" 'CURL_CA_BUNDLE="$GTLS_SYSTEM_CA_FILE"' "AppRun OpenPGP curl CA-Bundle"
    check_file_contains "$appdir/AppRun" "dinox_repair_accessibility_bus" "AppRun AT-SPI Reparatur"
    check_file_contains "$appdir/AppRun" "DINOX_REPAIR_A11Y_BUS" "AppRun AT-SPI harte Reparatur nur opt-in"
    check_file_contains "$appdir/AppRun" "org.freedesktop.DBus.ListNames" "AppRun AT-SPI Direktprobe"
    check_file_contains "$appdir/AppRun" "timeout 2 gdbus call" "AppRun AT-SPI Probe-Zeitlimit"
    check_file_contains "$appdir/AppRun" "$AT_SPI_REGISTRY_PGREP_PATTERN" "AppRun AT-SPI Registry-Reparatur"
    check_file_lacks "$appdir/AppRun" "NO_AT_BRIDGE=1" "AppRun Accessibility Bridge nicht deaktiviert"
    check_file_lacks "$appdir/AppRun" "GTK_A11Y=none" "AppRun Accessibility Backend nicht deaktiviert"
    check_file_contains "$appdir/AppRun" 'USER_ICON_BASE="${USER_DATA_HOME}/icons/hicolor"' "AppRun User-Icon-Theme"
    check_file_contains "$appdir/AppRun" 'gtk-update-icon-cache -q -t -f "${USER_ICON_BASE}"' "AppRun Icon-Cache Update"
    check_file_contains "$appdir/AppRun" 'DESKTOP_HINT_FILE="${DESKTOP_HINT_DIR}/im.dinox.dinox-appimage.desktop"' "AppRun Desktop-Datei Hint"
    check_file_contains "$appdir/AppRun" 'Icon=${APPDIR}/im.dinox.dinox.png' "AppRun absoluter Icon-Hint"
    check_file_contains "$appdir/AppRun" 'Exec=\"${APPDIR}/AppRun\" %U' "AppRun leerzeichenfester Desktop Exec-Hint"
    check_file_contains "$appdir/AppRun" 'BAMF_DESKTOP_FILE_HINT="${DESKTOP_HINT_FILE}"' "AppRun BAMF Desktop-Datei Hint"
    check_file_contains "$appdir/AppRun" 'LANG_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/dinox/language"' "AppRun XDG Sprachdatei"
    check_file_contains "$appdir/AppRun" 'echo "system" > "$LANG_FILE"' "AppRun Sprachdatei Default"
    check_desktop_file "$appdir/im.dinox.dinox.desktop" "AppDir Desktop-Datei"
    check_file_contains "$appdir/im.dinox.dinox.desktop" "Exec=dinox %U" "AppDir Desktop Exec"
    check_file_contains "$appdir/im.dinox.dinox.desktop" "Icon=im.dinox.dinox" "AppDir Desktop Icon"
    check_file_contains "$appdir/im.dinox.dinox.desktop" "MimeType=x-scheme-handler/xmpp;" "AppDir Desktop XMPP Handler"
    check_file_contains "$appdir/im.dinox.dinox.desktop" "dinox;" "AppDir Desktop Keyword DinoX"
    check_file_contains "$appdir/im.dinox.dinox.desktop" "omemo;" "AppDir Desktop Keyword OMEMO"
    check_file_contains "$appdir/im.dinox.dinox.desktop" "mqtt;" "AppDir Desktop Keyword MQTT"
    check_file_contains "$appdir/im.dinox.dinox.desktop" "botmother;" "AppDir Desktop Keyword Botmother"
    check_file_contains "$appdir/im.dinox.dinox.desktop" "StartupWMClass=dinox" "AppDir Desktop StartupWMClass"
    check_file "$appdir/im.dinox.dinox.png" "AppDir Root-Icon"
    check_file "$appdir/.DirIcon" "AppDir .DirIcon"
    [ -e "$appdir/.DirIcon" ] && check_symlink_target "$appdir/.DirIcon" "im.dinox.dinox.png" "AppDir .DirIcon Ziel"
    check_file "$appdir/usr/bin/dinox" "dinox Binary"
    check_file "$appdir/usr/bin/ffmpeg" "ffmpeg Binary für Nachrichten-Recorder"
    check_file "$appdir/usr/bin/gpg" "OpenPGP gpg"
    check_file "$appdir/usr/bin/gpgconf" "OpenPGP gpgconf"
    check_file "$appdir/usr/bin/gpg-agent" "OpenPGP gpg-agent"
    check_file "$appdir/usr/bin/dirmngr" "OpenPGP dirmngr"
    check_file "$appdir/usr/bin/gpg-connect-agent" "OpenPGP gpg-connect-agent"
    check_file "$appdir/usr/bin/curl" "OpenPGP Keyserver-curl"
    check_file "$appdir/usr/bin/gpgconf.ctl" "GnuPG relocatable Konfiguration"
    check_file_contains "$appdir/usr/bin/gpgconf.ctl" 'rootdir = ${APPDIR}/usr' "GnuPG AppDir-Root"
    check_file_contains "$appdir/usr/bin/gpgconf.ctl" 'sysconfdir = ${APPDIR}/usr/etc/gnupg' "GnuPG AppDir-Konfiguration"
    check_nonempty_file "$appdir/usr/share/gnupg/sks-keyservers.netCA.pem" "GnuPG Keyserver-CA"
    check_glob_absent "$appdir/usr/bin/gpgv*" "Nicht benötigtes gpgv"
    check_glob_absent "$appdir/usr/bin/gpgsm*" "Nicht benötigtes gpgsm"
    check_glob_absent "$appdir/usr/bin/pinentry*" "Nicht benötigtes pinentry"
    check_glob_absent "$appdir/usr/libexec/keyboxd*" "Nicht benötigtes keyboxd"
    check_glob_absent "$appdir/usr/libexec/scdaemon*" "Deaktiviertes scdaemon"
    check_file "$appdir/usr/bin/tor" "Tor Binary"
    check_nonempty_file "$appdir/usr/share/dinox/tor/geoip" "Tor GeoIP-Daten"
    check_nonempty_file "$appdir/usr/share/dinox/tor/geoip6" "Tor GeoIPv6-Daten"
    check_file "$appdir/usr/bin/lyrebird" "Lyrebird Binary"
    check_appstream_file "$appdir/usr/share/metainfo/im.dinox.dinox.appdata.xml" "AppDir AppStream Metainfo" false
    check_file_contains "$appdir/usr/share/metainfo/im.dinox.dinox.appdata.xml" "<id>im.dinox.dinox</id>" "AppStream ID"
    check_file "$appdir/usr/share/applications/im.dinox.dinox.desktop" "Desktop-Datei"
    check_files_equal "$appdir/im.dinox.dinox.desktop" "$appdir/usr/share/applications/im.dinox.dinox.desktop" "AppDir Desktop-Dateien identisch"
    check_file "$appdir/usr/share/dbus-1/services/im.dinox.dinox.service" "D-Bus Service-Datei"
    check_file_contains "$appdir/usr/share/dbus-1/services/im.dinox.dinox.service" "Name=im.dinox.dinox" "D-Bus Service Name"
    check_file_contains "$appdir/usr/share/dbus-1/services/im.dinox.dinox.service" "Exec=dinox" "D-Bus Service Exec"
    check_file "$appdir/usr/share/icons/hicolor/16x16/apps/im.dinox.dinox.png" "App-Icon 16x16"
    check_file "$appdir/usr/share/icons/hicolor/32x32/apps/im.dinox.dinox.png" "App-Icon 32x32"
    check_file "$appdir/usr/share/icons/hicolor/48x48/apps/im.dinox.dinox.png" "App-Icon 48x48"
    check_file "$appdir/usr/share/icons/hicolor/128x128/apps/im.dinox.dinox.png" "App-Icon 128x128"
    check_file "$appdir/usr/share/icons/hicolor/256x256/apps/im.dinox.dinox.png" "App-Icon 256x256"
    check_file "$appdir/usr/share/icons/hicolor/512x512/apps/im.dinox.dinox.png" "App-Icon 512x512"
    check_file "$appdir/usr/lib/gstreamer-1.0/gst-plugin-scanner" "gst-plugin-scanner"
    check_glob "$appdir/usr/share/locale/*/LC_MESSAGES/dino.mo" "DinoX Übersetzungen"
    check_glob_any "DinoX Plugins" \
        "$appdir/usr/lib/dino/plugins/*.so" \
        "$appdir/usr/lib/*-linux-gnu/dino/plugins/*.so"
    check_production_plugin_inventory "$appdir" "AppDir Produktionsplugin-Inventar"
    check_translation_catalog_inventory "$appdir" "AppDir Übersetzungskataloge"
    check_glob_any "Google/libwebrtc Plugin" \
        "$appdir/usr/lib/dino/plugins/google-webrtc.so" \
        "$appdir/usr/lib/*-linux-gnu/dino/plugins/google-webrtc.so"
    check_file "$appdir/usr/lib/dinox/libdinox-google-webrtc.so" "Google/libwebrtc Wrapper"
    check_file "$appdir/usr/lib/dinox/dinox-webrtc-worker" "Google/libwebrtc Worker"
    check_vision_runtime_bundle "$appdir/usr/lib/dinox" "AppDir Vision-Runtime"
    check_file "$appdir/usr/lib/dinox/libavcodec-dinox-hw.so.62" "Private WebRTC FFmpeg libavcodec"
    check_file "$appdir/usr/lib/dinox/libavutil-dinox-hw.so.60" "Private WebRTC FFmpeg libavutil"
    check_ibus_compat_package "$appdir/usr" "$appdir/usr/share/licenses/dinox"
    local notice
    while IFS= read -r notice; do
        check_file "$appdir/usr/share/licenses/dinox/google-libwebrtc/$notice" "Google/libwebrtc Notice $notice"
    done < <(google_libwebrtc_notice_files)
    local recorder_ffmpeg_metadata="$appdir/usr/share/licenses/dinox/corresponding-sources/recorder-ffmpeg/METADATA"
    local recorder_x264_metadata="$appdir/usr/share/licenses/dinox/corresponding-sources/recorder-x264/METADATA"
    local recorder_ffmpeg_source="$appdir/usr/share/licenses/dinox/corresponding-sources/recorder-ffmpeg/ffmpeg-$FFMPEG_RECORDER_VERSION.tar.xz"
    local recorder_x264_source="$appdir/usr/share/licenses/dinox/corresponding-sources/recorder-x264/x264-$X264_RECORDER_COMMIT.tar.gz"
    check_file "$recorder_ffmpeg_metadata" "Recorder-FFmpeg Quellmetadaten"
    check_file "$recorder_x264_metadata" "Recorder-x264 Quellmetadaten"
    check_file_contains "$recorder_ffmpeg_metadata" "checksum=$FFMPEG_RECORDER_SHA256" "Recorder-FFmpeg Quellprüfsumme"
    check_file_contains "$recorder_ffmpeg_metadata" "license_expression=GPL-2.0-or-later" "Recorder-FFmpeg GPL-Lizenz"
    check_file_contains "$recorder_x264_metadata" "checksum=$X264_RECORDER_SHA256" "Recorder-x264 Quellprüfsumme"
    check_file_contains "$recorder_x264_metadata" "license_expression=GPL-2.0-or-later" "Recorder-x264 GPL-Lizenz"
    check_file "$appdir/usr/share/licenses/dinox/custom-dependencies/recorder-ffmpeg/METADATA" "Recorder-FFmpeg Lizenzmetadaten"
    check_file "$appdir/usr/share/licenses/dinox/custom-dependencies/recorder-x264/METADATA" "Recorder-x264 Lizenzmetadaten"
    check_file "$appdir/usr/share/licenses/dinox/THIRD_PARTY_NOTICES.md" "AppImage Drittanbieter-Lizenzen/BOM"
    check_appdir_system_component_provenance "$appdir" gpg gnupg2 "OpenPGP gpg"
    check_appdir_system_component_provenance "$appdir" gpgconf gnupg2 "OpenPGP gpgconf/gpg-connect-agent"
    check_appdir_system_component_provenance "$appdir" gpg-agent gnupg2 "OpenPGP gpg-agent"
    check_appdir_system_component_provenance "$appdir" dirmngr gnupg2 "OpenPGP dirmngr"
    check_appdir_system_component_provenance "$appdir" curl curl "OpenPGP Keyserver-curl"
    if [ "$source_layout" = "full" ]; then
        diagnose_appdir_source_provenance \
            "$appdir" "$appdir/usr/share/licenses/dinox"
    else
        check_appdir_runtime_provenance "$appdir"
        check_slim_appdir_source_offer "$appdir"
    fi
    check_appdir_gstreamer_plugins "$appdir"
    check_glob "$appdir/usr/lib/dinox/libomemo-c.so*" "libomemo-c"
    check_glob "$appdir/usr/lib/dinox/libsqlcipher.so*" "SQLCipher"
    check_glob "$appdir/usr/lib/dinox/libnice.so*" "libnice"
    check_glob_absent "$appdir/usr/lib/gstreamer-1.0/libgstnice.so*" "Unbenutztes libnice GStreamer Plugin"
    check_glob_absent "$appdir/usr/lib/dinox/libwebrtc-audio-processing*.so*" "Alter WebRTC-Audio-Processing-Stack"
    check_glob "$appdir/usr/lib/dinox/libmosquitto.so*" "libmosquitto"
    check_glob "$appdir/usr/lib/dinox/libunbound.so.8*" "libunbound (DNSSEC)"
    check_glob "$appdir/usr/lib/dinox/libcjson.so*" "libcjson"
    check_single_library_payload "$appdir" 'libsqlcipher.so*' "AppDir SQLCipher"
    check_single_library_payload "$appdir" 'libnice.so*' "AppDir libnice"
    check_single_library_payload "$appdir" 'libomemo-c.so*' "AppDir libomemo-c"
    check_single_library_payload "$appdir" 'libmosquitto.so*' "AppDir libmosquitto"
    check_single_library_payload "$appdir" 'libcjson.so*' "AppDir cJSON"
    check_single_library_payload "$appdir" 'libprotobuf-c.so*' "AppDir protobuf-c"
    check_single_library_payload "$appdir" 'libavcodec-dinox-hw.so.62*' "AppDir private WebRTC libavcodec"
    check_single_library_payload "$appdir" 'libavutil-dinox-hw.so.60*' "AppDir private WebRTC libavutil"
    check_glob "$appdir/usr/lib/dinox/libevent*.so*" "libevent"
    check_private_recorder_codec_boundary \
        "$appdir/usr/bin/ffmpeg" "AppDir privater Recorder-ffmpeg"
    diagnose_linux_ffmpeg_recorder \
        "$appdir/usr/bin/ffmpeg" "$(appdir_library_path "$appdir")" "AppDir ffmpeg" libx264
    diagnose_appdir_gnupg_runtime "$appdir"
    check_no_absolute_elf_runtime_paths "$appdir" "AppDir ELF-Laufzeitpfade"
    check_bot_features_omemo_resolution "$appdir" "AppDir bot-features/OMEMO Plugin-Auflösung"
    check_google_webrtc_runtime_paths "$appdir" "AppDir Google/libwebrtc Plugin-Auflösung"
    check_all_elf_closure "$appdir" appdir "AppDir All-ELF Runtime-Closure"
}

diagnose_deb() {
    local deb="$1"
    section "Debian Paket"
    row_ok "Paket: $deb"
    local depends
    depends="$(dpkg-deb --field "$deb" Depends || true)"
    echo "  Depends: $depends"
    grep -Eq '(^|,)[[:space:]]*libunbound8[[:space:]]*\(>=[[:space:]]*1\.19\)([[:space:]]*,|$)' <<< "$depends" && row_ok "Deb libunbound Dependency" || row_fail "Deb libunbound Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*libsoup-3\.0-0[[:space:]]*\(>=[[:space:]]*3\.4\)([[:space:]]*,|$)' <<< "$depends" && row_ok "Deb libsoup 3.4 Dependency" || row_fail "Deb libsoup 3.4 Dependency fehlt"
    grep -Eq '(^|, )at-spi2-core([, ]|$)' <<< "$depends" && row_ok "Deb AT-SPI Accessibility Bus Dependency" || row_fail "Deb AT-SPI Accessibility Bus Dependency fehlt"
    grep -Eq '(^|, )libglib2\.0-bin([, ]|$)' <<< "$depends" && row_ok "Deb gdbus Runtime Dependency" || row_fail "Deb gdbus Runtime Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*gpg[[:space:]]*\(>=[[:space:]]*2\.4\)([[:space:]]*,|$)' <<< "$depends" && row_ok "Deb OpenPGP gpg 2.4 Dependency" || row_fail "Deb OpenPGP gpg 2.4 Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*gpgconf[[:space:]]*\(>=[[:space:]]*2\.4\)([[:space:]]*,|$)' <<< "$depends" && row_ok "Deb OpenPGP gpgconf 2.4 Dependency" || row_fail "Deb OpenPGP gpgconf 2.4 Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*gpg-agent[[:space:]]*\(>=[[:space:]]*2\.4\)([[:space:]]*,|$)' <<< "$depends" && row_ok "Deb OpenPGP gpg-agent 2.4 Dependency" || row_fail "Deb OpenPGP gpg-agent 2.4 Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*dirmngr[[:space:]]*\(>=[[:space:]]*2\.4\)([[:space:]]*,|$)' <<< "$depends" && row_ok "Deb OpenPGP dirmngr 2.4 Dependency" || row_fail "Deb OpenPGP dirmngr 2.4 Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*curl([[:space:](,]|$)' <<< "$depends" && row_ok "Deb OpenPGP curl Dependency" || row_fail "Deb OpenPGP curl Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*libicu74([[:space:](,]|$)' <<< "$depends" && row_ok "Deb Ubuntu-24/Mint-22 ICU ABI Dependency" || row_fail "Deb Ubuntu-24/Mint-22 ICU ABI Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*ffmpeg([[:space:](,]|$)' <<< "$depends" && row_ok "Deb ffmpeg Recorder Dependency" || row_fail "Deb ffmpeg Recorder Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*gstreamer1\.0-plugins-base([[:space:](,]|$)' <<< "$depends" && row_ok "Deb GStreamer Base Plugins Dependency" || row_fail "Deb GStreamer Base Plugins Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*gstreamer1\.0-plugins-good([[:space:](,]|$)' <<< "$depends" && row_ok "Deb GStreamer Good Plugins Dependency" || row_fail "Deb GStreamer Good Plugins Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*gstreamer1\.0-plugins-bad([[:space:](,]|$)' <<< "$depends" && row_ok "Deb GStreamer Bad Plugins Dependency" || row_fail "Deb GStreamer Bad Plugins Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*gstreamer1\.0-libav([[:space:](,]|$)' <<< "$depends" && row_ok "Deb GStreamer libav Decoder Dependency" || row_fail "Deb GStreamer libav Decoder Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*libssl3t64([[:space:](,]|$)|(^|,)[[:space:]]*libssl3([[:space:](,]|$)' <<< "$depends" && row_ok "Deb OpenSSL Runtime Dependency" || row_fail "Deb OpenSSL Runtime Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*libsrtp2-1([[:space:](,]|$)' <<< "$depends" && row_ok "Deb SRTP Runtime Dependency" || row_fail "Deb SRTP Runtime Dependency fehlt"
    grep -Eq '(^|,)[[:space:]]*libva2([[:space:](,]|$)' <<< "$depends" && row_ok "Deb libva Runtime Dependency" || row_fail "Deb libva Runtime Dependency fehlt"
    local contents
    contents="$(dpkg-deb --contents "$deb")"
    grep -q '/usr/bin/dinox$' <<< "$contents" && row_ok "dinox Binary" || row_fail "dinox Binary fehlt"
    grep -q '/usr/bin/dinox.real$' <<< "$contents" && row_ok "dinox.real Wrapper-Ziel" || row_warn "dinox.real nicht gefunden"
    grep -q '/usr/lib/dinox/tor$' <<< "$contents" && row_ok "Tor Binary" || row_fail "Tor Binary fehlt"
    grep -q '/usr/lib/dinox/tor.real$' <<< "$contents" && row_ok "Tor Wrapper-Ziel" || row_fail "Tor Wrapper-Ziel fehlt"
    grep -q '/usr/share/dinox/tor/geoip$' <<< "$contents" && row_ok "Tor GeoIP-Daten" || row_fail "Tor GeoIP-Daten fehlen"
    grep -q '/usr/share/dinox/tor/geoip6$' <<< "$contents" && row_ok "Tor GeoIPv6-Daten" || row_fail "Tor GeoIPv6-Daten fehlen"
    grep -q '/usr/lib/dinox/lyrebird$' <<< "$contents" && row_ok "Lyrebird Binary" || row_fail "Lyrebird Binary fehlt"
    grep -Eq '/usr/lib/([^/]+/)?dino/plugins/[^/]+\.so$' <<< "$contents" && row_ok "DinoX Plugins" || row_fail "DinoX Plugins fehlen"
    grep -Eq '/usr/share/locale/[^/]+/LC_MESSAGES/dino\.mo$' <<< "$contents" && row_ok "DinoX Übersetzungen" || row_fail "DinoX Übersetzungen fehlen"
    grep -q '/usr/share/metainfo/im.dinox.dinox.appdata.xml$' <<< "$contents" && row_ok "AppStream Metainfo" || row_fail "AppStream Metainfo fehlt"
    grep -q '/usr/share/applications/im.dinox.dinox.desktop$' <<< "$contents" && row_ok "Desktop-Datei" || row_fail "Desktop-Datei fehlt"
    grep -q '/usr/share/icons/hicolor/16x16/apps/im.dinox.dinox.png$' <<< "$contents" && row_ok "App-Icon 16x16" || row_fail "App-Icon 16x16 fehlt"
    grep -q '/usr/share/icons/hicolor/32x32/apps/im.dinox.dinox.png$' <<< "$contents" && row_ok "App-Icon 32x32" || row_fail "App-Icon 32x32 fehlt"
    grep -q '/usr/share/icons/hicolor/48x48/apps/im.dinox.dinox.png$' <<< "$contents" && row_ok "App-Icon 48x48" || row_fail "App-Icon 48x48 fehlt"
    grep -q '/usr/share/icons/hicolor/128x128/apps/im.dinox.dinox.png$' <<< "$contents" && row_ok "App-Icon 128x128" || row_fail "App-Icon 128x128 fehlt"
    grep -q '/usr/share/icons/hicolor/256x256/apps/im.dinox.dinox.png$' <<< "$contents" && row_ok "App-Icon 256x256" || row_fail "App-Icon 256x256 fehlt"
    grep -q '/usr/share/icons/hicolor/512x512/apps/im.dinox.dinox.png$' <<< "$contents" && row_ok "App-Icon 512x512" || row_fail "App-Icon 512x512 fehlt"
    grep -q '/usr/share/dbus-1/services/im.dinox.dinox.service$' <<< "$contents" && row_ok "D-Bus Service-Datei" || row_fail "D-Bus Service-Datei fehlt"
    grep -q '/usr/lib/dinox/dinox-init-language.sh$' <<< "$contents" && row_ok "Deb Sprachinitialisierung" || row_fail "Deb Sprachinitialisierung fehlt"
    grep -q '/etc/xdg/autostart/dinox-init-language.desktop$' <<< "$contents" && row_ok "Deb Sprach-Autostart" || row_fail "Deb Sprach-Autostart fehlt"
    check_deb_file_lacks "$deb" "/usr/bin/dinox" "GST_PLUGIN_PATH=" "Deb Wrapper ohne privaten GStreamer Pluginpfad"
    check_deb_file_lacks "$deb" "/usr/bin/dinox" "GST_PLUGIN_SYSTEM_PATH=" "Deb Wrapper ohne privaten GStreamer Systempfad"
    check_deb_file_contains "$deb" "/usr/bin/dinox" "LD_LIBRARY_PATH=/usr/lib/dinox" "Deb Wrapper private Bibliothekspfade"
    check_deb_file_contains "$deb" "/usr/bin/dinox" "DINOX_TOR_PATH=/usr/lib/dinox/tor" "Deb Wrapper Tor-Pfad"
    check_deb_file_contains "$deb" "/usr/bin/dinox" "DINOX_TOR_DATA_DIR=/usr/share/dinox/tor" "Deb Wrapper Tor-Datenpfad"
    check_deb_file_contains "$deb" "/usr/bin/dinox" "DINOX_LYREBIRD_PATH=/usr/lib/dinox/lyrebird" "Deb Wrapper Lyrebird-Pfad"
    check_deb_file_contains "$deb" "/usr/bin/dinox" "dinox_repair_accessibility_bus" "Deb Wrapper AT-SPI Reparatur"
    check_deb_file_contains "$deb" "/usr/bin/dinox" "DINOX_REPAIR_A11Y_BUS" "Deb Wrapper AT-SPI harte Reparatur nur opt-in"
    check_deb_file_contains "$deb" "/usr/bin/dinox" "org.freedesktop.DBus.ListNames" "Deb Wrapper AT-SPI Direktprobe"
    check_deb_file_contains "$deb" "/usr/bin/dinox" "timeout 2 gdbus call" "Deb Wrapper AT-SPI Probe-Zeitlimit"
    check_deb_file_contains "$deb" "/usr/bin/dinox" "$AT_SPI_REGISTRY_PGREP_PATTERN" "Deb Wrapper AT-SPI Registry-Reparatur"
    check_deb_file_lacks "$deb" "/usr/bin/dinox" "NO_AT_BRIDGE=1" "Deb Wrapper Accessibility Bridge nicht deaktiviert"
    check_deb_file_lacks "$deb" "/usr/bin/dinox" "GTK_A11Y=none" "Deb Wrapper Accessibility Backend nicht deaktiviert"
    if grep -q '/etc/ld.so.conf.d/dinox.conf$' <<< "$contents"; then
        row_fail "Deb privater Bibliothekspfad ist global in ld.so.conf registriert"
    else
        row_ok "Deb private Bibliotheken nicht global in ld.so.conf registriert"
    fi
    check_deb_appstream_file "$deb" "/usr/share/metainfo/im.dinox.dinox.appdata.xml" "AppStream Metainfo"
    check_deb_file_contains "$deb" "/usr/share/metainfo/im.dinox.dinox.appdata.xml" "<id>im.dinox.dinox</id>" "AppStream ID"
    check_deb_desktop_file "$deb" "/usr/share/applications/im.dinox.dinox.desktop" "Desktop-Datei"
    check_deb_file_contains "$deb" "/usr/share/applications/im.dinox.dinox.desktop" "Exec=dinox %U" "Desktop Exec"
    check_deb_file_contains "$deb" "/usr/share/applications/im.dinox.dinox.desktop" "Icon=im.dinox.dinox" "Desktop Icon"
    check_deb_file_contains "$deb" "/usr/share/applications/im.dinox.dinox.desktop" "MimeType=x-scheme-handler/xmpp;" "Desktop XMPP Handler"
    check_deb_file_contains "$deb" "/usr/share/applications/im.dinox.dinox.desktop" "dinox;" "Desktop Keyword DinoX"
    check_deb_file_contains "$deb" "/usr/share/applications/im.dinox.dinox.desktop" "omemo;" "Desktop Keyword OMEMO"
    check_deb_file_contains "$deb" "/usr/share/applications/im.dinox.dinox.desktop" "mqtt;" "Desktop Keyword MQTT"
    check_deb_file_contains "$deb" "/usr/share/applications/im.dinox.dinox.desktop" "botmother;" "Desktop Keyword Botmother"
    check_deb_file_contains "$deb" "/usr/share/applications/im.dinox.dinox.desktop" "StartupWMClass=dinox" "Desktop StartupWMClass"
    check_deb_file_contains "$deb" "/usr/share/dbus-1/services/im.dinox.dinox.service" "Name=im.dinox.dinox" "D-Bus Service Name"
    check_deb_file_contains "$deb" "/usr/share/dbus-1/services/im.dinox.dinox.service" "Exec=dinox" "D-Bus Service Exec"
    check_deb_file_contains "$deb" "/usr/lib/dinox/dinox-init-language.sh" 'LANG_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/dinox/language"' "Deb XDG Sprachdatei"
    check_deb_file_contains "$deb" "/usr/lib/dinox/dinox-init-language.sh" 'echo "system" > "$LANG_FILE"' "Deb Sprachdatei Default"
    check_deb_file_contains "$deb" "/etc/xdg/autostart/dinox-init-language.desktop" "Exec=/usr/lib/dinox/dinox-init-language.sh" "Deb Sprach-Autostart Exec"
    if grep -qE '/usr/lib/dinox/gstreamer-1.0/' <<< "$contents"; then
        row_fail "Deb private GStreamer Plugins nicht gebündelt"
    else
        row_ok "Deb private GStreamer Plugins nicht gebündelt"
    fi
    grep -q '/usr/lib/dinox/libomemo-c' <<< "$contents" && row_ok "libomemo-c gebündelt" || row_fail "libomemo-c fehlt"
    grep -q '/usr/lib/dinox/libsqlcipher' <<< "$contents" && row_ok "SQLCipher gebündelt" || row_fail "SQLCipher fehlt"
    grep -q '/usr/lib/dinox/libnice' <<< "$contents" && row_ok "libnice gebündelt" || row_fail "libnice fehlt"
    if grep -q 'libgstnice\.so' <<< "$contents"; then
        row_fail "Unbenutztes libnice GStreamer Plugin ist im Deb gebündelt"
    else
        row_ok "Unbenutztes libnice GStreamer Plugin nicht gebündelt"
    fi
    grep -qE '/usr/lib(/[^/]+-linux-gnu)?/dino/plugins/google-webrtc.so$' <<< "$contents" && row_ok "Google/libwebrtc Plugin gebündelt" || row_fail "Google/libwebrtc Plugin fehlt"
    grep -q '/usr/lib/dinox/libdinox-google-webrtc.so$' <<< "$contents" && row_ok "Google/libwebrtc Wrapper gebündelt" || row_fail "Google/libwebrtc Wrapper fehlt"
    grep -q '/usr/lib/dinox/dinox-webrtc-worker$' <<< "$contents" && row_ok "Google/libwebrtc Worker gebündelt" || row_fail "Google/libwebrtc Worker fehlt"
    grep -q '/usr/lib/dinox/dinox-vision-worker$' <<< "$contents" && row_ok "Vision-Worker gebündelt" || row_fail "Vision-Worker fehlt"
    grep -q '/usr/lib/dinox/libavcodec-dinox-hw.so.62$' <<< "$contents" && row_ok "Private WebRTC FFmpeg libavcodec gebündelt" || row_fail "Private WebRTC FFmpeg libavcodec fehlt"
    grep -q '/usr/lib/dinox/libavutil-dinox-hw.so.60$' <<< "$contents" && row_ok "Private WebRTC FFmpeg libavutil gebündelt" || row_fail "Private WebRTC FFmpeg libavutil fehlt"
    local notice
    while IFS= read -r notice; do
        grep -qF "/usr/share/licenses/dinox/google-libwebrtc/$notice" <<< "$contents" \
            && row_ok "Google/libwebrtc Notice $notice gebündelt" \
            || row_fail "Google/libwebrtc Notice $notice fehlt"
    done < <(google_libwebrtc_notice_files)
    grep -qF '/usr/share/licenses/dinox/google-libwebrtc/sources/ffmpeg-8.1.2.tar.xz' <<< "$contents" \
        && row_ok "FFmpeg exakter Quellstand gebündelt" || row_fail "FFmpeg exakter Quellstand fehlt"
    grep -qF '/usr/share/licenses/dinox/google-libwebrtc/sources/libva-2.20.0.tar.gz' <<< "$contents" \
        && row_ok "libva exakter Quellstand gebündelt" || row_fail "libva exakter Quellstand fehlt"
    grep -qF '/usr/share/licenses/dinox/google-libwebrtc/sources/nv-codec-headers-n8.1.24.15.tar.gz' <<< "$contents" \
        && row_ok "NVIDIA exakte Headerquellen gebündelt" || row_fail "NVIDIA exakte Headerquellen fehlen"
    grep -qF '/usr/share/licenses/dinox/google-libwebrtc/sources/ffmpeg-dinox-symbol-versions.patch' <<< "$contents" \
        && row_ok "Privater FFmpeg-Symbolpatch gebündelt" || row_fail "Privater FFmpeg-Symbolpatch fehlt"
    grep -qF '/usr/share/licenses/dinox/google-libwebrtc/sources/webrtc-m152-codec-sources-6f37672d3584-sha256-2b17c14cc13b.tar.gz' <<< "$contents" \
        && row_ok "M152 exakte Codecquellen gebündelt" || row_fail "M152 exakte Codecquellen fehlen"
    grep -qF '/usr/share/doc/dinox/copyright' <<< "$contents" \
        && row_ok "Deb Copyright-Datei" || row_fail "Deb Copyright-Datei fehlt"
    grep -qF '/usr/share/licenses/dinox/THIRD_PARTY_NOTICES.md' <<< "$contents" \
        && row_ok "Deb Drittanbieter-Lizenzen/BOM" || row_fail "Deb Drittanbieter-Lizenzen/BOM fehlt"
    if grep -q '/usr/lib/dinox/libwebrtc-audio-processing' <<< "$contents"; then
        row_fail "Alter WebRTC-Audio-Processing-Stack unerwartet gebündelt"
    else
        row_ok "Alter WebRTC-Audio-Processing-Stack nicht gebündelt"
    fi
    grep -q '/usr/lib/dinox/libmosquitto' <<< "$contents" && row_ok "libmosquitto gebündelt" || row_fail "libmosquitto fehlt"
    grep -q '/usr/lib/dinox/libcjson' <<< "$contents" && row_ok "libcjson gebündelt" || row_fail "libcjson fehlt"
    grep -q '/usr/lib/dinox/tor-libs/libevent' <<< "$contents" && row_ok "libevent für Tor gebündelt" || row_fail "libevent für Tor fehlt"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    if dpkg-deb -x "$deb" "$tmp_dir" >/dev/null 2>&1; then
        check_vision_runtime_bundle "$tmp_dir/usr/lib/dinox" "Deb Vision-Runtime"
        check_ibus_compat_package "$tmp_dir/usr" "$tmp_dir/usr/share/licenses/dinox"
        check_ibus_compat_source_recipe "$tmp_dir/usr" "$tmp_dir/usr/share/licenses/dinox"
        check_file "$tmp_dir/usr/share/licenses/dinox/corresponding-sources/ibus-compat/ibus_1.5.30.orig.tar.gz" \
            "Deb IBus exaktes Quellarchiv"
        check_file_sha256 "$tmp_dir/usr/share/licenses/dinox/corresponding-sources/ibus-compat/ibus_1.5.30.orig.tar.gz" \
            "$IBUS_COMPAT_SOURCE_SHA256" "Deb IBus exakter Quellstand"
        check_release_forbidden_artifacts \
            "$tmp_dir" "Deb Release-Artefakt-Inventar"
        check_nonempty_file "$tmp_dir/usr/share/dinox/tor/geoip" "Deb Tor GeoIP-Daten"
        check_nonempty_file "$tmp_dir/usr/share/dinox/tor/geoip6" "Deb Tor GeoIPv6-Daten"
        check_single_library_payload "$tmp_dir" 'libsqlcipher.so*' "Deb SQLCipher"
        check_single_library_payload "$tmp_dir" 'libnice.so*' "Deb libnice"
        check_single_library_payload "$tmp_dir" 'libomemo-c.so*' "Deb libomemo-c"
        check_single_library_payload "$tmp_dir" 'libmosquitto.so*' "Deb libmosquitto"
        check_single_library_payload "$tmp_dir" 'libcjson.so*' "Deb cJSON"
        check_single_library_payload "$tmp_dir" 'libprotobuf-c.so*' "Deb protobuf-c"
        check_single_library_payload "$tmp_dir" 'libavcodec-dinox-hw.so.62*' "Deb private WebRTC libavcodec"
        check_single_library_payload "$tmp_dir" 'libavutil-dinox-hw.so.60*' "Deb private WebRTC libavutil"
        check_production_plugin_inventory "$tmp_dir" "Deb Produktionsplugin-Inventar"
        check_translation_catalog_inventory "$tmp_dir" "Deb Übersetzungskataloge"
        check_no_absolute_elf_runtime_paths "$tmp_dir" "Deb ELF-Laufzeitpfade"
        check_bot_features_omemo_resolution "$tmp_dir" "Deb bot-features/OMEMO Plugin-Auflösung"
        check_google_webrtc_runtime_paths "$tmp_dir" "Deb Google/libwebrtc Plugin-Auflösung"
        check_all_elf_closure "$tmp_dir" deb "Deb All-ELF Runtime-Closure"
    else
        row_fail "Deb All-ELF Runtime-Closure nicht geprüft; Paket konnte nicht extrahiert werden"
    fi
    rm -rf "$tmp_dir"
}

manifest_has() {
    local manifest="$1" pattern="$2" label="$3" required="${4:-true}"
    if grep -qF -- "$pattern" "$manifest"; then
        row_ok "$label"
    elif [ "$required" = "true" ]; then
        row_fail "$label fehlt ($pattern)"
    else
        row_warn "$label fehlt ($pattern)"
    fi
}

manifest_lacks() {
    local manifest="$1" pattern="$2" label="$3"
    if grep -qF -- "$pattern" "$manifest"; then
        row_fail "$label unerwartet vorhanden ($pattern)"
    else
        row_ok "$label"
    fi
}

manifest_module_config_has() {
    local manifest="$1" module="$2" option="$3" label="$4"
    if have_cmd jq; then
        if jq -e --arg module_name "$module" --arg option "$option" \
                'any(.modules[]?; .name == $module_name and any((."config-opts"? // [])[]?; . == $option))' \
                "$manifest" >/dev/null 2>&1; then
            row_ok "$label"
        else
            row_fail "$label fehlt ($module: $option)"
        fi
    else
        row_warn "$label nicht geprüft; jq fehlt"
    fi
}

check_json_file() {
    local path="$1" label="${2:-JSON Syntax}"
    if have_cmd jq; then
        jq empty "$path" >/dev/null 2>&1 && row_ok "$label" || row_fail "$label ungültig"
    elif have_cmd python3; then
        python3 -m json.tool "$path" >/dev/null 2>&1 && row_ok "$label" || row_fail "$label ungültig"
    else
        row_warn "$label nicht geprüft; jq oder python3 fehlt"
    fi
}

check_xml_file() {
    local path="$1" label="${2:-XML Syntax}"
    if have_cmd xmllint; then
        xmllint --noout "$path" >/dev/null 2>&1 && row_ok "$label" || row_fail "$label ungültig"
    elif have_cmd python3; then
        python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$path" >/dev/null 2>&1 \
            && row_ok "$label" || row_fail "$label ungültig"
    else
        row_warn "$label nicht geprüft; xmllint oder python3 fehlt"
    fi
}

appstream_screenshot_assets_valid() {
    local path="$1"
    local root="${2:-.}"
    local require_tracked="${3:-true}"
    local output=""
    APPSTREAM_SCREENSHOT_ERROR=""

    if ! have_cmd python3; then
        APPSTREAM_SCREENSHOT_ERROR="python3 fehlt"
        return 2
    fi

    if ! output="$(
        python3 - "$path" "$root" "$require_tracked" <<'PY'
import os
import re
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET

path, root, require_tracked = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
tree = ET.parse(path)
found = 0
errors = []
raw_url_pattern = re.compile(
    r"^https://git\.dinox\.im/dinoxim/dinox/raw/"
    r"(?:branch/master|tag/v[0-9][^/]*|commit/[0-9a-fA-F]{40})/"
    r"(.+)$"
)
git_env = os.environ.copy()
if os.path.abspath(root) != os.getcwd():
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
        git_env.pop(name, None)


def png_size(asset_path):
    with open(asset_path, "rb") as handle:
        header = handle.read(24)
    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError("not a PNG")
    return struct.unpack(">II", header[16:24])


for elem in tree.getroot().iter():
    if elem.tag.rsplit("}", 1)[-1] != "image":
        continue
    url = (elem.text or "").strip()
    if not url:
        continue
    match = raw_url_pattern.match(url)
    if not match:
        errors.append(f"ungueltige URL: {url}")
        continue
    rel = match.group(1)
    if rel.startswith("/") or ".." in rel.split("/"):
        errors.append(f"ungueltiger Asset-Pfad: {url}")
        continue
    found += 1
    asset_path = os.path.join(root, rel)
    if not os.path.isfile(asset_path):
        errors.append(f"fehlendes Asset: {rel}")
        continue
    if require_tracked:
        result = subprocess.run(
            ["git", "-C", root, "ls-files", "--error-unmatch", rel],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=git_env,
            check=False,
        )
        if result.returncode != 0:
            errors.append(f"nicht getracktes Asset: {rel}")
    width = elem.get("width")
    height = elem.get("height")
    if width is None or height is None:
        errors.append(f"fehlende Bildmasse: {rel}")
        continue
    try:
        declared = (int(width), int(height))
        actual = png_size(asset_path)
    except Exception as exc:
        errors.append(f"Bildmasse nicht lesbar: {rel} ({exc})")
        continue
    if declared != actual:
        errors.append(
            f"Bildmasse falsch: {rel} deklariert {declared[0]}x{declared[1]}, "
            f"Datei {actual[0]}x{actual[1]}"
        )

if found == 0:
    errors.append("keine Forgejo Screenshot-Assets gefunden")
if errors:
    print("; ".join(errors))
    sys.exit(1)
PY
    )"; then
        APPSTREAM_SCREENSHOT_ERROR="${output:-AppStream Screenshot-Assets konnten nicht gelesen werden}"
        return 1
    fi
}

check_appstream_screenshot_assets() {
    local path="$1"
    if appstream_screenshot_assets_valid "$path" "." true; then
        row_ok "AppStream Screenshot Assets"
    elif [ "$APPSTREAM_SCREENSHOT_ERROR" = "python3 fehlt" ]; then
        row_warn "AppStream Screenshot Assets nicht geprüft; python3 fehlt"
    else
        row_fail "AppStream Screenshot Assets ungültig (${APPSTREAM_SCREENSHOT_ERROR})"
    fi
}

check_appstream_file() {
    local path="$1" label="${2:-AppStream Metainfo}" check_screenshots="${3:-true}"
    check_file "$path" "$label"
    [ -f "$path" ] || return 0
    check_xml_file "$path" "$label XML Syntax"
    if have_cmd appstreamcli; then
        appstreamcli validate --no-net "$path" >/dev/null 2>&1 \
            && row_ok "$label gültig" || row_fail "$label ungültig"
    else
        row_warn "$label nicht geprüft; appstreamcli fehlt"
    fi
    if [ "$check_screenshots" = "true" ]; then
        check_appstream_screenshot_assets "$path"
    fi
}

check_desktop_file() {
    local path="$1" label="${2:-Desktop-Datei}"
    check_file "$path" "$label"
    [ -f "$path" ] || return 0
    if have_cmd desktop-file-validate; then
        desktop-file-validate "$path" >/dev/null 2>&1 \
            && row_ok "$label gültig" || row_fail "$label ungültig"
    else
        row_warn "$label nicht geprüft; desktop-file-validate fehlt"
    fi
}

diagnose_metadata() {
    section "App-Metadaten"
    check_appstream_file "main/data/im.dinox.dinox.appdata.xml"
    check_desktop_file "main/data/im.dinox.dinox.desktop"
    manifest_has "main/data/im.dinox.dinox.appdata.xml" '<url type="homepage">https://dinox.im</url>' "AppStream Homepage"
    manifest_has "main/data/im.dinox.dinox.appdata.xml" '<url type="bugtracker">https://git.dinox.im/dinoxim/dinox/issues</url>' "AppStream Bugtracker"
    manifest_has "main/data/im.dinox.dinox.appdata.xml" '<url type="vcs-browser">https://git.dinox.im/dinoxim/dinox</url>' "AppStream VCS"
    manifest_has "main/data/im.dinox.dinox.appdata.xml" '<update_contact>contact@dinox.im</update_contact>' "AppStream Kontakt"
    manifest_has "main/data/im.dinox.dinox.appdata.xml" '<keyword translate="no">DinoX</keyword>' "AppStream Keyword DinoX"
    manifest_has "main/data/im.dinox.dinox.appdata.xml" '<keyword translate="no">OMEMO</keyword>' "AppStream Keyword OMEMO"
    manifest_has "main/data/im.dinox.dinox.appdata.xml" '<keyword translate="no">MQTT</keyword>' "AppStream Keyword MQTT"
    manifest_has "main/data/im.dinox.dinox.appdata.xml" '<keyword translate="no">Botmother</keyword>' "AppStream Keyword Botmother"
    manifest_has "main/data/im.dinox.dinox.desktop" 'dinox;' "Desktop Keyword DinoX"
    manifest_has "main/data/im.dinox.dinox.desktop" 'omemo;' "Desktop Keyword OMEMO"
    manifest_has "main/data/im.dinox.dinox.desktop" 'mqtt;' "Desktop Keyword MQTT"
    manifest_has "main/data/im.dinox.dinox.desktop" 'botmother;' "Desktop Keyword Botmother"
}

diagnose_flatpak_manifest() {
    local manifest="$1"
    section "Flatpak Manifest"
    check_file "$manifest" "Manifest"
    [ -f "$manifest" ] || return

    check_json_file "$manifest" "Manifest JSON Syntax"
    manifest_has "$manifest" '"id": "im.dinox.dinox"' "App-ID"
    manifest_has "$manifest" '"runtime": "org.gnome.Platform"' "GNOME Runtime"
    manifest_has "$manifest" '"runtime-version": "50"' "GNOME Runtime 50"
    manifest_lacks "$manifest" 'GST_PLUGIN_PATH=' "Flatpak verwendet Runtime-GStreamer-Pfade"
    manifest_lacks "$manifest" 'LD_LIBRARY_PATH=' "Flatpak ohne globalen privaten Bibliothekspfad"
    manifest_lacks "$manifest" '"--no-a11y-bus"' "Accessibility Bus nicht deaktiviert"
    manifest_lacks "$manifest" 'NO_AT_BRIDGE' "Accessibility Bridge nicht deaktiviert"
    manifest_lacks "$manifest" 'GTK_A11Y=none' "Accessibility Backend nicht deaktiviert"
    manifest_lacks "$manifest" '"--socket=gpg-agent"' "Host-GPG-Agent nicht freigegeben"
    manifest_lacks "$manifest" '"--talk-name=org.freedesktop.portal.Desktop"' "Portal-Busname nicht direkt freigegeben"
    manifest_lacks "$manifest" '"--system-talk-name=org.freedesktop.login1"' "login1 System-Bus nicht freigegeben"
    manifest_lacks "$manifest" '"--own-name=im.dinox.dinox"' "App-ID Own-Name nicht explizit gesetzt"
    manifest_lacks "$manifest" '"--filesystem=xdg-cache/dinox:create"' "Host-XDG-Cachepfad nicht freigegeben"
    manifest_lacks "$manifest" '"--filesystem=xdg-data/dinox:create"' "Host-XDG-Datenpfad nicht freigegeben"
    manifest_has "$manifest" '"--filesystem=home:ro"' "Home-Verzeichnis nur lesbar für Datei-DnD"
    manifest_lacks "$manifest" '"--filesystem=home"' "Kein schreibbarer Home-Zugriff"
    manifest_lacks "$manifest" '"--filesystem=home:rw"' "Kein explizit schreibbarer Home-Zugriff"
    manifest_lacks "$manifest" '"--filesystem=home:create"' "Kein erstellender Home-Zugriff"
    manifest_lacks "$manifest" '"--filesystem=host' "Kein hostweiter Dateisystemzugriff"
    manifest_has "$manifest" '"--socket=pulseaudio"' "PulseAudio Socket"
    manifest_lacks "$manifest" '"--filesystem=xdg-run/pipewire-0"' "Alter PipeWire-Dateisystemzugriff entfernt"
    manifest_has "$manifest" '"--device=all"' "Device Zugriff"
    manifest_has "$manifest" '"--talk-name=org.freedesktop.secrets"' "Secret-Service Zugriff"
    manifest_has "$manifest" '"--talk-name=org.kde.StatusNotifierWatcher"' "SNI-Tray Watcher Zugriff"
    manifest_has "$manifest" '"--talk-name=org.x.StatusNotifierWatcher"' "SNI-Tray Fallback Watcher Zugriff"
    manifest_lacks "$manifest" '"name": "openh264"' "Kein selbstgebautes OpenH264 Modul"
    manifest_has "$manifest" '"name": "libnice"' "libnice Modul"
    manifest_module_config_has "$manifest" "libnice" "-Dgstreamer=disabled" "libnice GStreamer Plugin deaktiviert"
    manifest_module_config_has "$manifest" "libnice" "-Dexamples=disabled" "libnice Beispiele deaktiviert"
    manifest_module_config_has "$manifest" "libnice" "-Dintrospection=disabled" "libnice Introspection deaktiviert"
    manifest_has "$manifest" '"/bin/stunbdc"' "libnice stunbdc Runtime-Cleanup"
    manifest_has "$manifest" '"/bin/stund"' "libnice stund Runtime-Cleanup"
    manifest_lacks "$manifest" '"name": "pipewire"' "Altes GStreamer-PipeWire-Capture-Modul entfernt"
    manifest_lacks "$manifest" '/app/etc/pipewire' "Alte private PipeWire-Konfiguration entfernt"
    manifest_lacks "$manifest" '"name": "webrtc-audio-processing"' "Altes WebRTC Audio Processing Modul entfernt"
    manifest_has "$manifest" '"name": "libomemo-c"' "libomemo-c Modul"
    manifest_has "$manifest" '"name": "sqlcipher"' "SQLCipher Modul"
    manifest_has "$manifest" "SQLITE_ENABLE_FTS5" "SQLCipher FTS5 aktiviert"
    manifest_has "$manifest" '"name": "cjson"' "cJSON Modul"
    manifest_has "$manifest" '"name": "mosquitto"' "Mosquitto Modul"
    manifest_has "$manifest" '"name": "tor"' "Tor Modul"
    manifest_has "$manifest" '"name": "lyrebird"' "Lyrebird Modul"
    manifest_has "$manifest" '"-Dplugin-rtp=disabled"' "Altes RTP Plugin deaktiviert"
    manifest_has "$manifest" '"-Dplugin-google-webrtc=enabled"' "Google/libwebrtc Plugin aktiviert"
    manifest_has "$manifest" '"-Dgoogle-libwebrtc-wrapper=enabled"' "Google/libwebrtc Wrapper aktiviert"
    manifest_has "$manifest" '"-Dgoogle-libwebrtc-test-oracle=false"' "Google/libwebrtc Test-Oracle deaktiviert"
    manifest_has "$manifest" '"-Dgoogle-libwebrtc-tests=false"' "Google/libwebrtc Paket-Smokes deaktiviert"
    manifest_has "$manifest" 'libwebrtc-m152-linux-x86_64-runtime-abi40-ipc10-sha256-2479cdb9ab7e.tar.gz' "Google/libwebrtc Runtime-Artefakt"
    manifest_has "$manifest" '2479cdb9ab7eace826e28d519a9dd33478329e34c303ed716c196005d9cec46f' "Google/libwebrtc Runtime mit dynamischem FFmpeg und exakten Quellen"
    manifest_has "$manifest" 'packaging/flatpak/THIRD_PARTY_NOTICES.md' "Flatpak Drittanbieter-Inventar"
    manifest_has "$manifest" 'install -Dm0755 /run/build/dino/scripts/check-flatpak-runtime.sh /app/libexec/dinox-flatpak-runtime-gate' "Flatpak Runtime-Gate wird installiert"
    manifest_lacks "$manifest" '"/app/libexec/dinox-flatpak-runtime-gate layout"' "Kein Flatpak Layout-Gate vor Cleanup/Export"
    manifest_has "$manifest" '"-Dplugin-http-files=enabled"' "HTTP-Datei-Plugin aktiviert"
    manifest_has "$manifest" '"-Dplugin-ice=enabled"' "ICE-/Dateitransfer-Plugin aktiviert"
    manifest_has "$manifest" '"-Dplugin-omemo=enabled"' "OMEMO Plugin aktiviert"
    manifest_has "$manifest" '"-Dplugin-openpgp=enabled"' "OpenPGP Plugin aktiviert"
    manifest_has "$manifest" '"-Dplugin-notification-sound=enabled"' "Benachrichtigungston-Plugin aktiviert"
    manifest_has "$manifest" '"-Dplugin-mqtt=enabled"' "MQTT Plugin aktiviert"
    manifest_module_config_has "$manifest" "dino" "-Ddnssec=enabled" "DNSSEC/DANE aktiviert"
    manifest_has "$manifest" '"-Dlocation-sharing=enabled"' "Location Sharing aktiviert"
    manifest_has "$manifest" '"-Dplugin-rtp-vaapi=disabled"' "VAAPI im Flatpak deaktiviert" false
    manifest_has "$manifest" '"--nofilesystem=~/.local/share/dinox"' "Host-Datenpfad explizit gesperrt" false
    manifest_has "$manifest" '"--talk-name=org.freedesktop.GeoClue2"' "GeoClue2 Zugriff"
    manifest_has "$manifest" '"--unset-env=LC_ALL"' "LC_ALL wird nicht auf C.UTF-8 festgenagelt" false
    manifest_has "$manifest" '"separate-locales": false' "Übersetzungen im Haupt-Flatpak"
    if [ -x scripts/check-flatpak-runtime.sh ]; then
        scripts/check-flatpak-runtime.sh manifest "$manifest" packaging/flatpak/THIRD_PARTY_NOTICES.md \
            && row_ok "Flatpak Architektur-/Lizenz-Gate" \
            || row_fail "Flatpak Architektur-/Lizenz-Gate fehlgeschlagen"
    else
        row_fail "Flatpak Architektur-/Lizenz-Gate fehlt"
    fi
}

diagnose_local_build_configuration() {
    local build_dir="${1:-build}"
    local options_file="$build_dir/meson-info/intro-buildoptions.json"
    local option_rows runtime_root name expected_value actual_value
    local -a required_options=(
        plugin-rtp
        plugin-google-webrtc
        google-libwebrtc-wrapper
        google-libwebrtc-test-oracle
        google-libwebrtc-tests
        plugin-mqtt
        plugin-http-files
        plugin-ice
        plugin-omemo
        plugin-openpgp
        plugin-notification-sound
        location-sharing
    )
    local -A expected=(
        [plugin-rtp]=disabled
        [plugin-google-webrtc]=enabled
        [google-libwebrtc-wrapper]=enabled
        [google-libwebrtc-test-oracle]=false
        [google-libwebrtc-tests]=false
        [plugin-mqtt]=enabled
        [plugin-http-files]=enabled
        [plugin-ice]=enabled
        [plugin-omemo]=enabled
        [plugin-openpgp]=enabled
        [plugin-notification-sound]=enabled
        [location-sharing]=enabled
    )
    local -A actual=()

    section "Lokale Produktionskonfiguration"
    if [ ! -s "$options_file" ]; then
        row_fail "Meson-Buildoptionen fehlen ($options_file)"
        return
    fi
    if ! have_cmd python3; then
        row_fail "Meson-Buildoptionen nicht geprüft; python3 fehlt"
        return
    fi
    if ! option_rows="$(
        python3 - "$options_file" <<'PY'
import json
import pathlib
import sys

options = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for option in options:
    value = option.get("value")
    if isinstance(value, bool):
        value = str(value).lower()
    print(f"{option.get('name', '')}\t{value}")
PY
    )"; then
        row_fail "Meson-Buildoptionen sind nicht lesbar"
        return
    fi

    while IFS=$'\t' read -r name actual_value; do
        [ -n "$name" ] && actual["$name"]="$actual_value"
    done <<< "$option_rows"

    for name in "${required_options[@]}"; do
        expected_value="${expected[$name]}"
        actual_value="${actual[$name]:-<fehlt>}"
        if [ "$actual_value" = "$expected_value" ]; then
            row_ok "Meson $name=$expected_value"
        else
            row_fail "Meson $name=$actual_value (erwartet: $expected_value)"
        fi
    done

    runtime_root="${actual[google-libwebrtc-runtime-root]:-}"
    if [ -z "$runtime_root" ]; then
        row_fail "Meson google-libwebrtc-runtime-root fehlt"
    elif [ ! -d "$runtime_root" ]; then
        row_fail "Google/libwebrtc Runtime-Root fehlt ($runtime_root)"
    elif "$PROJECT_ROOT/scripts/check-libwebrtc-linux-runtime.sh" "$runtime_root" >/dev/null; then
        row_ok "Google/libwebrtc Runtime-Root validiert"
    else
        row_fail "Google/libwebrtc Runtime-Root ungültig ($runtime_root)"
    fi

    check_file "$build_dir/plugins/google-webrtc/google-webrtc.so" \
        "Google/libwebrtc Plugin im lokalen Build"
}

case "$MODE" in
    system|local)
        TARGET="${TARGET:-build}"
        section "Lokaler Referenz-Build"
        check_file "$TARGET/main/dinox" "$TARGET/main/dinox"
        diagnose_local_build_configuration "$TARGET"
        diagnose_gstreamer
        diagnose_linux_ffmpeg_recorder "$(command -v ffmpeg 2>/dev/null || true)" "" "System ffmpeg"
        ;;
    appdir)
        TARGET="${TARGET:-AppDir}"
        if [ ! -d "$TARGET" ]; then
            section "AppDir Dateien"
            row_fail "AppDir fehlt ($TARGET)"
        else
            setup_appdir_env "$TARGET"
            diagnose_appdir_files "$TARGET" slim
            diagnose_gstreamer
        fi
        ;;
    appdir-full)
        TARGET="${TARGET:-AppDir}"
        if [ ! -d "$TARGET" ]; then
            section "AppDir Dateien"
            row_fail "AppDir fehlt ($TARGET)"
        else
            setup_appdir_env "$TARGET"
            diagnose_appdir_files "$TARGET" full
            diagnose_gstreamer
        fi
        ;;
    appdir-provenance)
        if [ ! -d "$TARGET" ]; then
            section "AppImage Source-Sidecar"
            row_fail "AppDir fehlt ($TARGET)"
        elif [ ! -d "$SOURCE_TARGET" ]; then
            section "AppImage Source-Sidecar"
            row_fail "extrahierter Lizenzbaum fehlt ($SOURCE_TARGET)"
        else
            diagnose_appdir_source_sidecar_provenance "$TARGET" "$SOURCE_TARGET"
        fi
        ;;
    deb)
        requested_target="$TARGET"
        TARGET="${TARGET:-$(ls -1t ./*.deb 2>/dev/null | head -1 || true)}"
        if [ -z "$TARGET" ] || [ ! -f "$TARGET" ]; then
            section "Debian Paket"
            if [ -n "$requested_target" ]; then
                row_fail "Debian-Paket nicht gefunden ($requested_target)"
            else
                row_fail "Debian-Paket nicht gefunden"
            fi
        else
            diagnose_deb "$TARGET"
        fi
        ;;
    flatpak-manifest)
        TARGET="${TARGET:-im.dinox.dinox.json}"
        diagnose_flatpak_manifest "$TARGET"
        ;;
    metadata)
        diagnose_metadata
        ;;
    self-test)
        run_self_test
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        red "Unbekannter Modus: $MODE"
        usage
        exit 2
        ;;
esac

echo
echo "== Ergebnis $MODE =="
green "  OK:   $ok_count"
yellow "  WARN: $warn_count"
if [ "$fail_count" -gt 0 ]; then
    red "  FAIL: $fail_count"
    exit 1
fi
green "  FAIL: 0"
