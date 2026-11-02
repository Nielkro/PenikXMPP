#!/bin/bash
set -euo pipefail

# --- Konfiguration ---
APP_NAME="dinox"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="$(cat "$PROJECT_ROOT/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
VERSION="${VERSION:-1.1.8.1}"
ARCH="amd64"
PKG_ROOT="pkg_dinox"
MAINTAINER="DinoX Team <contact@dinox.im>"
BUILD_DIR="$PROJECT_ROOT/build-deb-package"
TOR_REQUIRED_VERSION="0.4.9.12"
LYREBIRD_REQUIRED_VERSION="0.8.1"
MESON_COMPILE_ARGS=()
STRICT=false
LICENSE_SOURCE_MAP=""
CUSTOM_DEPENDENCY_PREFIX="${DINOX_CUSTOM_DEPENDENCY_PREFIX:-/opt/dinox-deps}"
CUSTOM_DEPENDENCY_BINDIR="$CUSTOM_DEPENDENCY_PREFIX/bin"
CUSTOM_DEPENDENCY_LIBDIR="$CUSTOM_DEPENDENCY_PREFIX/lib"
IBUS_COMPAT_PREFIX="$PROJECT_ROOT/.vendor-deps/ibus-compat-deb"
export DINOX_IBUS_COMPAT_PREFIX="$IBUS_COMPAT_PREFIX"

export PATH="$CUSTOM_DEPENDENCY_BINDIR${PATH:+:$PATH}"
export PKG_CONFIG_PATH="$CUSTOM_DEPENDENCY_LIBDIR/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CMAKE_PREFIX_PATH="$CUSTOM_DEPENDENCY_PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$CUSTOM_DEPENDENCY_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [ -n "${DINOX_BUILD_JOBS:-${DINOX_CI_JOBS:-}}" ]; then
    DINOX_EFFECTIVE_JOBS="${DINOX_BUILD_JOBS:-${DINOX_CI_JOBS:-}}"
    if ! [[ "$DINOX_EFFECTIVE_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        echo "FEHLER: ungueltiges DinoX Build-Job-Limit: $DINOX_EFFECTIVE_JOBS" >&2
        exit 2
    fi
    MESON_COMPILE_ARGS=(-j "$DINOX_EFFECTIVE_JOBS")
fi

usage() {
    cat <<EOF
Usage: $0 [--strict] [-h|--help]

Builds the DinoX Debian package.
--strict fails the single clean package compilation on compiler warnings.

This is a package-builder entry point, not a workstation bootstrap command.
Run it only in the verified DinoX Ubuntu 24.04 package-builder image; the
pinned dependencies under /opt/dinox-deps are mandatory.

Required environment:
  DINOX_LIBWEBRTC_RUNTIME_ROOT  Validated compact Linux runtime root

DINOX_LIBWEBRTC_ARTIFACT_ROOT is deliberately not accepted by this release
package entry point.
EOF
}

if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    usage
    exit 0
fi

if [ "$#" -eq 1 ] && [ "$1" = "--strict" ]; then
    STRICT=true
elif [ "$#" -gt 0 ]; then
    echo "Unknown arguments: $*" >&2
    usage >&2
    exit 2
fi

if [ -n "${DINOX_LIBWEBRTC_ARTIFACT_ROOT:-}" ]; then
    echo "FEHLER: DINOX_LIBWEBRTC_ARTIFACT_ROOT wird von Linux-Paketbuilds nicht unterstützt." >&2
    echo "Nutze für Entwicklungs-/Proof-Builds scripts/configure-libwebrtc-wrapper-build.sh --artifact-root und erzeuge daraus zuerst den kompakten Runtime-Root." >&2
    echo "DinoX-Deb-Releases benötigen ausschließlich DINOX_LIBWEBRTC_RUNTIME_ROOT." >&2
    exit 1
fi
if [ -z "${DINOX_LIBWEBRTC_RUNTIME_ROOT:-}" ]; then
    echo "FEHLER: Für ein DinoX-Deb-Release ist der validierte Google/libwebrtc-Runtime-Root erforderlich." >&2
    echo "Setze DINOX_LIBWEBRTC_RUNTIME_ROOT." >&2
    exit 1
fi

# Hilfsfunktion: Bibliothek suchen und alle .so-Varianten kopieren
# Strategie: ldconfig-Pfade direkt verwenden (kein find im Verzeichnis nötig)
copy_lib() {
    local pattern="$1"
    local dest="$2"
    local required="${3:-false}"
    local base="${pattern/\*/}"   # z.B. "libomemo-c.so"
    local found=false

    # Alle Pfade aus ldconfig holen (folgt bereits Symlinks auf /lib → /usr/lib)
    # und zusätzlich find -L für Libs die noch nicht in ldconfig registriert sind
    local all_paths
    all_paths=$(
        # Strategie 1: ldconfig — kennt alle registrierten Libs inkl. /lib-Symlinks
        ldconfig -p 2>/dev/null \
            | grep -F "$base" \
            | awk -F' => ' '{print $2}' \
            | xargs -I{} realpath -e {} 2>/dev/null || true

        # Strategie 2: find -L (folgt Symlink-Verzeichnissen wie /lib → /usr/lib)
        find -L /usr/local/lib /usr/lib /lib \
            -maxdepth 3 -name "$pattern" \( -type f -o -type l \) 2>/dev/null || true
    )

    # Deduplizieren und kopieren
    local copied=()
    while IFS= read -r fpath; do
        [ -z "$fpath" ] && continue
        local fname
        fname=$(basename "$fpath")
        # Doppelte überspringen (realpath + find können gleiche Datei liefern)
        [[ " ${copied[*]} " == *" $fname "* ]] && continue
        if cp -P "$fpath" "$dest/" 2>/dev/null; then
            copied+=("$fname")
            found=true
            record_distribution_source "$dest/$fname" "$fpath"
        fi
    done < <(echo "$all_paths" | sort -u)

    if $found; then
        echo "  ✓ $pattern → $dest (${#copied[@]} Dateien: ${copied[*]})"
    elif [ "$required" = "true" ]; then
        echo "FEHLER: Pflichtbibliothek '$pattern' nicht gefunden!" >&2
        echo "  Debug: find -L /usr /lib -name '$pattern' 2>/dev/null:" >&2
        find -L /usr /lib -name "$pattern" 2>/dev/null >&2 || echo "  (wirklich nirgends gefunden)" >&2
        exit 1
    else
        echo "  WARNUNG: '$pattern' nicht gefunden, wird übersprungen."
    fi
}

# ci-build-deps.sh installs release-only dependencies into a private prefix.
# Copy exactly that payload; never infer "custom" ownership from /usr because
# doing so can silently combine different distro and release ABIs.
copy_custom_lib() {
    local pattern="$1"
    local dest="$2"
    local required="${3:-false}"
    local found=false
    local candidate
    mkdir -p "$dest"
    while IFS= read -r -d '' candidate; do
        cp -a "$candidate" "$dest/"
        found=true
    done < <(find "$CUSTOM_DEPENDENCY_LIBDIR" -maxdepth 1 -name "$pattern" \
        \( -type f -o -type l \) -print0 2>/dev/null)

    if $found; then
        echo "  ✓ $pattern → $dest (aus $CUSTOM_DEPENDENCY_LIBDIR)"
    elif [ "$required" = "true" ]; then
        echo "FEHLER: selbst gebaute Pflichtbibliothek '$pattern' nicht gefunden!" >&2
        exit 1
    else
        echo "  WARNUNG: selbst gebaute Bibliothek '$pattern' nicht gefunden, wird übersprungen."
    fi
}

record_distribution_source() {
    local packaged_path="$1"
    local source_path="$2"
    local relative_path canonical_source

    [ -n "$LICENSE_SOURCE_MAP" ] || {
        echo "FEHLER: Lizenz-Provenienzdatei ist beim Kopieren einer Distributionsdatei nicht initialisiert." >&2
        exit 1
    }
    command -v dpkg-query >/dev/null 2>&1 || {
        echo "FEHLER: dpkg-query fehlt; Eigentümer von $source_path kann nicht belegt werden." >&2
        exit 1
    }
    case "$packaged_path" in
        "$PKG_ROOT"/*) ;;
        *)
            echo "FEHLER: kopierter Paketpfad liegt außerhalb von $PKG_ROOT: $packaged_path" >&2
            exit 1
            ;;
    esac
    canonical_source="$(readlink -f -- "$source_path" 2>/dev/null || true)"
    [ -n "$canonical_source" ] && [ -e "$canonical_source" ] || {
        echo "FEHLER: kopierte Distributionsquelle ist nicht kanonisierbar: $source_path" >&2
        exit 1
    }
    dpkg-query -S -- "$canonical_source" >/dev/null 2>&1 || {
        echo "FEHLER: keine Debian-Paketeigentümerschaft für kopierte Runtime-Datei: $canonical_source" >&2
        exit 1
    }
    relative_path="${packaged_path#"$PKG_ROOT"/}"
    printf '%s\t%s\n' "$relative_path" "$canonical_source" >> "$LICENSE_SOURCE_MAP"
}

# Hilfsfunktion: Binary suchen und kopieren
copy_bin() {
    local name="$1"
    local dest="$2"
    local required="${3:-true}"

    local path
    path="$CUSTOM_DEPENDENCY_BINDIR/$name"

    if [ ! -x "$path" ]; then
        if [ "$required" = "true" ]; then
            echo "FEHLER: private Binary '$name' nicht gefunden: $path" >&2
            exit 1
        else
            echo "  WARNUNG: Binary '$name' nicht gefunden, wird übersprungen."
            return
        fi
    fi

    echo "  Kopiere $name von $path"
    cp "$path" "$dest/"
    chmod 755 "$dest/$name"
}

is_blacklisted_elf_dep() {
    local name="$1"
    case "$name" in
        libc.so*|libm.so*|libdl.so*|librt.so*|libpthread.so*|ld-linux*.so*|linux-vdso.so*|libnss_*.so*)
            return 0
            ;;
    esac
    return 1
}

copy_elf_deps_recursive() {
    local file="$1"
    local dest="$2"
    [ -e "$file" ] || return 0
    mkdir -p "$dest"

    if [ -z "${__DINOX_DEB_DEPS_SEEN_INIT:-}" ]; then
        declare -gA __DINOX_DEB_DEPS_SEEN
        __DINOX_DEB_DEPS_SEEN_INIT=1
    fi

    local dep
    while IFS= read -r dep; do
        [ -e "$dep" ] || continue
        local base
        base="$(basename "$dep")"
        is_blacklisted_elf_dep "$base" && continue
        [ -n "${__DINOX_DEB_DEPS_SEEN[$base]:-}" ] && continue
        __DINOX_DEB_DEPS_SEEN[$base]=1
        cp -L "$dep" "$dest/" 2>/dev/null || true
        if [ -e "$dest/$base" ]; then
            record_distribution_source "$dest/$base" "$dep"
            copy_elf_deps_recursive "$dest/$base" "$dest"
        fi
    done < <(ldd "$file" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i}')
}

require_elf_deps_resolved() {
    local file="$1"
    local lib_path="$2"
    local label="$3"

    if LD_LIBRARY_PATH="$lib_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$file" 2>/dev/null | grep "not found" >/dev/null; then
        echo "FEHLER: ungelöste Runtime-Abhängigkeiten für $label ($file):" >&2
        LD_LIBRARY_PATH="$lib_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$file" >&2 || true
        exit 1
    fi
    echo "  ✓ $label Runtime-Abhängigkeiten vollständig"
}

require_build_needed() {
    local path="$1"
    local soname="$2"
    local label="$3"

    [ -s "$path" ] || {
        echo "FEHLER: Build-Ausgabe für $label fehlt: $path" >&2
        exit 1
    }
    readelf -d "$path" 2>/dev/null | grep -F "Shared library: [$soname]" >/dev/null \
        || {
            echo "FEHLER: $label wurde nicht gegen den erwarteten privaten SONAME $soname gebaut." >&2
            readelf -d "$path" >&2 || true
            exit 1
        }
    echo "  ✓ $label verwendet $soname"
}

create_tor_wrapper() {
    local wrapper="$1"
    local real_binary="$2"
    local tor_lib_dir="$3"
    local base_dir

    base_dir="$(basename "$tor_lib_dir")"
    mv "$wrapper" "$real_binary"
    cat > "$wrapper" <<TORWRAPPER
#!/bin/bash
set -e
SELF="\$0"
case "\$SELF" in
    */*) ;;
    *) SELF="\$(command -v "\$SELF")" ;;
esac
BASE="\$(dirname "\$(readlink -f "\$SELF")")"
export LD_LIBRARY_PATH="\$BASE/$base_dir:\$BASE\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$BASE/$(basename "$real_binary")" "\$@"
TORWRAPPER
    chmod 755 "$wrapper"
}

require_tor_version() {
    local bin="$1"
    local version
    version="$("$bin" --version 2>/dev/null | head -1 | sed -nE 's/^Tor version ([0-9]+(\.[0-9]+)*).*/\1/p')"
    if [ "$version" != "$TOR_REQUIRED_VERSION" ]; then
        echo "FEHLER: falsche Tor-Version in $bin: '${version:-unbekannt}', erwartet $TOR_REQUIRED_VERSION" >&2
        echo "  CI muss scripts/ci-build-deps.sh ausführen, damit $CUSTOM_DEPENDENCY_BINDIR/tor $TOR_REQUIRED_VERSION bereitsteht." >&2
        exit 1
    fi
    echo "  ✓ Tor-Version $version"
}

require_lyrebird_version() {
    local bin="$1"
    local version
    version="$("$bin" --version 2>/dev/null | head -1 | sed -nE 's/^lyrebird ([^[:space:]]+).*/\1/p')"
    if [ "$version" != "$LYREBIRD_REQUIRED_VERSION" ]; then
        echo "FEHLER: falsche Lyrebird-Version in $bin: '${version:-unbekannt}', erwartet $LYREBIRD_REQUIRED_VERSION" >&2
        echo "  CI muss scripts/ci-build-deps.sh ausführen oder Lyrebird mit -X main.lyrebirdVersion=$LYREBIRD_REQUIRED_VERSION bauen." >&2
        exit 1
    fi
    echo "  ✓ Lyrebird-Version $version"
}

# ── 0. Meson neu konfigurieren & kompilieren mit ALLEN Features ───────────────
echo "=== Schritt 0: Meson mit allen Plugins konfigurieren ==="

[ -d "$CUSTOM_DEPENDENCY_LIBDIR/pkgconfig" ] || {
    echo "FEHLER: isolierte CI-Abhängigkeiten fehlen unter $CUSTOM_DEPENDENCY_PREFIX." >&2
    echo "Der Paket-Builder muss zuerst scripts/ci-build-deps.sh ausführen." >&2
    exit 1
}
bash "$PROJECT_ROOT/scripts/verify-ci-deps.sh"
bash "$PROJECT_ROOT/scripts/prepare-ibus-compat.sh" --prefix "$IBUS_COMPAT_PREFIX"

WEBRTC_RUNTIME_ROOT="${DINOX_LIBWEBRTC_RUNTIME_ROOT:-}"
WEBRTC_MESON_ARGS=(
    --prefix=/usr
    --buildtype=debugoptimized
    -Dplugin-mqtt=enabled
    -Ddnssec=enabled
    -Dplugin-rtp=disabled
    -Dplugin-google-webrtc=enabled
    -Dgoogle-libwebrtc-wrapper=enabled
    -Dgoogle-libwebrtc-test-oracle=false
    -Dgoogle-libwebrtc-tests=false
    -Dlocation-sharing=enabled
    -Dplugin-http-files=enabled
    -Dplugin-ice=enabled
    -Dplugin-omemo=enabled
    -Dplugin-openpgp=enabled
    -Dplugin-notification-sound=enabled
)

# Paketbuilds starten immer aus einem eigenen, leeren Meson-Verzeichnis. So
# können veraltete Optionen aus Entwickler-Builds nicht in ein Release geraten.
rm -rf "$BUILD_DIR"
meson setup "$BUILD_DIR" "$PROJECT_ROOT" \
    "${WEBRTC_MESON_ARGS[@]}" \
    "-Dgoogle-libwebrtc-runtime-root=$WEBRTC_RUNTIME_ROOT"

echo "  Kompiliere..."
if [ "${#MESON_COMPILE_ARGS[@]}" -gt 0 ]; then
    echo "  Build-Jobs: ${MESON_COMPILE_ARGS[1]}"
fi
if $STRICT; then
    bash "$PROJECT_ROOT/scripts/build.sh" --strict --build-dir "$BUILD_DIR"
else
    meson compile -C "$BUILD_DIR" "${MESON_COMPILE_ARGS[@]}"
fi
require_build_needed "$BUILD_DIR/qlite/libqlite.so.0.1" libsqlcipher.so.0 "QLite/SQLCipher"
require_build_needed "$BUILD_DIR/plugins/ice/ice.so" libnice.so.10 "Jingle ICE/libnice"
require_build_needed "$BUILD_DIR/plugins/omemo/omemo.so" libomemo-c.so.0 "OMEMO/libomemo-c"
require_build_needed "$BUILD_DIR/plugins/mqtt/mqtt.so" libmosquitto.so.1 "MQTT/libmosquitto"
require_build_needed "$BUILD_DIR/xmpp-vala/libxmpp-vala.so.0.1" libunbound.so.8 "DNSSEC/libunbound"

# The package's clean optimized tree is also its local runtime reference.
bash "$PROJECT_ROOT/scripts/package-runtime-matrix.sh" system "$BUILD_DIR"

# ── 1. Saubere Paketstruktur ──────────────────────────────────────────────────
echo "=== Schritt 1: Paketstruktur aufbauen ==="
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/DEBIAN"
mkdir -p "$PKG_ROOT/usr/bin"
mkdir -p "$PKG_ROOT/usr/lib/dinox"
LICENSE_SOURCE_MAP="$PWD/$PKG_ROOT/.dinox-license-sources.tsv"
: > "$LICENSE_SOURCE_MAP"

# ── 2. Alle DinoX-Dateien via Meson installieren ─────────────────────────────
echo "=== Schritt 2: Meson install ==="
DESTDIR="$(pwd)/$PKG_ROOT" meson install --no-rebuild -C "$BUILD_DIR"

# Lokale Builds installieren nach /usr/local — ins Paket gehört /usr
if [ -d "$PKG_ROOT/usr/local" ]; then
    echo "  Verschiebe /usr/local nach /usr..."
    cp -a "$PKG_ROOT/usr/local/." "$PKG_ROOT/usr/"
    rm -rf "$PKG_ROOT/usr/local"
fi

# Keep this optional client fallback outside every default library search path.
install -D -m 0644 \
    "$IBUS_COMPAT_PREFIX/lib/dinox/ibus-compat/libibus-1.0.so.5.0.530" \
    "$PKG_ROOT/usr/lib/dinox/ibus-compat/libibus-1.0.so.5.0.530"
install -m 0644 "$IBUS_COMPAT_PREFIX/lib/dinox/ibus-compat/METADATA" \
    "$PKG_ROOT/usr/lib/dinox/ibus-compat/METADATA"

# ── 3. Tor bündeln ────────────────────────────────────────────────────────────
echo "=== Schritt 3: Tor-Binary bündeln ==="
copy_bin "tor" "$PKG_ROOT/usr/lib/dinox"
require_tor_version "$PKG_ROOT/usr/lib/dinox/tor"
mkdir -p "$PKG_ROOT/usr/lib/dinox/tor-libs"
create_tor_wrapper "$PKG_ROOT/usr/lib/dinox/tor" "$PKG_ROOT/usr/lib/dinox/tor.real" "$PKG_ROOT/usr/lib/dinox/tor-libs"
require_tor_version "$PKG_ROOT/usr/lib/dinox/tor"
TOR_DATA_SOURCE="$CUSTOM_DEPENDENCY_PREFIX/share/tor"
TOR_DATA_DEST="$PKG_ROOT/usr/share/dinox/tor"
for tor_data_file in geoip geoip6; do
    [ -s "$TOR_DATA_SOURCE/$tor_data_file" ] || {
        echo "FEHLER: private Tor-Datendatei fehlt: $TOR_DATA_SOURCE/$tor_data_file" >&2
        exit 1
    }
    install -D -m 0644 "$TOR_DATA_SOURCE/$tor_data_file" "$TOR_DATA_DEST/$tor_data_file"
done

# ── 4. Lyrebird bündeln ───────────────────────────────────────────────────────
echo "=== Schritt 4: Lyrebird-Binary bündeln ==="
copy_bin "lyrebird" "$PKG_ROOT/usr/lib/dinox"
require_lyrebird_version "$PKG_ROOT/usr/lib/dinox/lyrebird"

# ── 5. Gebündelte Bibliotheken ────────────────────────────────────────────────
echo "=== Schritt 5: Isolierte Bibliotheken kopieren ==="

echo "  Private Build-Abhängigkeiten: $CUSTOM_DEPENDENCY_PREFIX"

LIBDIR="$PKG_ROOT/usr/lib/dinox"
TOR_LIBDIR="$LIBDIR/tor-libs"

copy_custom_lib "libsqlcipher.so*"              "$LIBDIR" true
copy_custom_lib "libomemo-c.so*"                "$LIBDIR" true
copy_custom_lib "libnice.so*"                   "$LIBDIR" true
copy_custom_lib "libmosquitto.so*"              "$LIBDIR" true   # MQTT
copy_custom_lib "libcjson.so*"                  "$LIBDIR" true   # Mosquitto runtime
copy_lib "libevent-*.so*"                       "$TOR_LIBDIR" true   # Private Tor runtime
copy_lib "libevent_core*.so*"                   "$TOR_LIBDIR" false  # Private Tor runtime
copy_lib "libevent_pthreads*.so*"               "$TOR_LIBDIR" false  # Private Tor runtime
copy_lib "libevent_extra*.so*"                  "$TOR_LIBDIR" false  # Private Tor runtime
copy_lib "libevent_openssl*.so*"                "$TOR_LIBDIR" false  # Private Tor runtime
copy_custom_lib "libprotobuf-c.so*"             "$LIBDIR" true   # OMEMO-Abhängigkeit

copy_elf_deps_recursive "$LIBDIR/tor.real" "$TOR_LIBDIR"
for elf in "$LIBDIR/tor.real" "$LIBDIR/lyrebird" "$LIBDIR"/libmosquitto.so* "$LIBDIR"/libcjson.so*; do
    [ -e "$elf" ] && require_elf_deps_resolved "$elf" "$TOR_LIBDIR:$LIBDIR" "$(basename "$elf")"
done

# ── 6. Medien-Runtime ─────────────────────────────────────────────────────────
echo "=== Schritt 6: Medien-Runtime über Debian-Abhängigkeiten ==="
echo "  Google/libwebrtc besitzt Calls und Geräteaufnahme."
echo "  ffmpeg schreibt M4A/MP4; systemweite GStreamer-Pakete demuxen/dekodieren."
echo "  Keine privaten GStreamer-Call- oder Encoder-Plugins werden gebündelt."

# ── 7. RPATH / ld.so.conf ────────────────────────────────────────────────────
echo "=== Schritt 7: Private Library-Loader-Isolation ==="
echo "  /usr/lib/dinox bleibt ausschließlich über den DinoX-Wrapper sichtbar."

# Start-Wrapper für private DinoX-Bibliotheken und die gebündelten
# Tor-/Lyrebird-Binaries. GStreamer kommt beim Deb vollständig aus den
# deklarierten Distributionspaketen und benötigt keinen privaten Pluginpfad.
BINARY_PATH=$(find "$PKG_ROOT/usr/bin" -name "dinox" 2>/dev/null | head -1 || true)
if [ -n "$BINARY_PATH" ]; then
    REAL_BINARY="${BINARY_PATH}.real"
    mv "$BINARY_PATH" "$REAL_BINARY"
    cat > "$BINARY_PATH" <<'WRAPPER'
#!/bin/bash
set -e

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

SELF="$0"
case "$SELF" in
    */*) ;;
    *) SELF="$(command -v "$SELF")" ;;
esac
SELF_DIR="$(dirname "$(readlink -f "$SELF")")"
export LD_LIBRARY_PATH=/usr/lib/dinox${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
# Tor und Lyrebird liegen in /usr/lib/dinox (privat, kein Konflikt mit System-tor)
export DINOX_TOR_PATH=/usr/lib/dinox/tor
export DINOX_LYREBIRD_PATH=/usr/lib/dinox/lyrebird
export DINOX_TOR_DATA_DIR=/usr/share/dinox/tor
dinox_repair_accessibility_bus
exec "$SELF_DIR/dinox.real" "$@"
WRAPPER
    chmod 755 "$BINARY_PATH"
fi

# ── 8. Lizenz- und Komponentenmaterial ───────────────────────────────────────
echo "=== Schritt 8: Lizenz- und Komponentenmaterial ==="
chmod +x "$PROJECT_ROOT/scripts/stage-package-licenses.sh"
"$PROJECT_ROOT/scripts/stage-package-licenses.sh" \
    --mode deb \
    --root "$PKG_ROOT" \
    --source-map "$LICENSE_SOURCE_MAP"
rm -f "$LICENSE_SOURCE_MAP"

# ── 9. DEBIAN/control ────────────────────────────────────────────────────────
echo "=== Schritt 9: DEBIAN-Steuerungsdateien ==="

# Installierte Größe berechnen
INSTALLED_SIZE=$(du -sk "$PKG_ROOT" | cut -f1)

cat > "$PKG_ROOT/DEBIAN/control" <<EOF
Package: $APP_NAME
Version: $VERSION
Architecture: $ARCH
Installed-Size: $INSTALLED_SIZE
Maintainer: $MAINTAINER
Depends: libadwaita-1-0, libgtk-4-1, at-spi2-core, libglib2.0-bin, libsoup-3.0-0 (>= 3.4), libgcrypt20, libgee-0.8-2, libgpgme11t64, gpg (>= 2.4), gpgconf (>= 2.4), gpg-agent (>= 2.4), dirmngr (>= 2.4), curl, libqrencode4, libsecret-1-0, libssl3t64 | libssl3, libunbound8 (>= 1.19), libicu74, libxml2, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, gstreamer1.0-plugins-bad, gstreamer1.0-libav, ffmpeg, libsrtp2-1, libva2, libva-drm2, libcanberra0, libgeoclue-2-0, heif-gdk-pixbuf, webp-pixbuf-loader, libheif-plugin-dav1d
Section: net
Priority: optional
Description: DinoX - Moderner XMPP-Client mit Google/libwebrtc
 Für Ubuntu 24.04 und Linux Mint 22.x (amd64). Auf Debian 13/Trixie
 und dessen Ablegern stattdessen AppImage oder Flatpak verwenden.
 DinoX ist ein moderner XMPP-Client auf Basis von GTK4/libadwaita.
 Dieser Build enthält den Google/libwebrtc-Worker für Audio-/Videoanrufe und
 Geräteaufnahme sowie private Tor-, Lyrebird-, SQLCipher-, OMEMO-, ICE- und
 MQTT-Komponenten. ffmpeg schreibt Chat-Audio/-Video; GStreamer demuxt und
 dekodiert Medien bei der Wiedergabe.
EOF

# ── 10. postinst ─────────────────────────────────────────────────────────────
# Autostart-Script das beim ersten Login die Sprachdatei anlegt
mkdir -p "$PKG_ROOT/usr/lib/dinox"
cat > "$PKG_ROOT/usr/lib/dinox/dinox-init-language.sh" <<'INITEOF'
#!/bin/bash
# Wird beim ersten Login ausgeführt und legt die Sprachdatei an
LANG_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/dinox/language"
if [ ! -f "$LANG_FILE" ]; then
    mkdir -p "$(dirname "$LANG_FILE")"
    echo "system" > "$LANG_FILE"
fi
# Einmalig — danach sich selbst aus Autostart entfernen
rm -f "$HOME/.config/autostart/dinox-init-language.desktop"
INITEOF
chmod 755 "$PKG_ROOT/usr/lib/dinox/dinox-init-language.sh"

# Autostart-Desktop-Eintrag
mkdir -p "$PKG_ROOT/etc/xdg/autostart"
cat > "$PKG_ROOT/etc/xdg/autostart/dinox-init-language.desktop" <<'DESKTOPEOF'
[Desktop Entry]
Type=Application
Name=DinoX Language Init
Exec=/usr/lib/dinox/dinox-init-language.sh
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
Comment=Initialize DinoX language setting on first login
DESKTOPEOF

cat > "$PKG_ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -e
ldconfig
glib-compile-schemas /usr/share/glib-2.0/schemas/ || true
[ -x "$(command -v update-desktop-database)" ] && update-desktop-database -q /usr/share/applications || true
[ -x "$(command -v gtk-update-icon-cache)" ]   && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
EOF
chmod 755 "$PKG_ROOT/DEBIAN/postinst"

# ── 11. postrm ───────────────────────────────────────────────────────────────
cat > "$PKG_ROOT/DEBIAN/postrm" <<'EOF'
#!/bin/bash
ldconfig
glib-compile-schemas /usr/share/glib-2.0/schemas/ || true
[ -x "$(command -v update-desktop-database)" ] && update-desktop-database -q /usr/share/applications || true
[ -x "$(command -v gtk-update-icon-cache)" ]   && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
exit 0
EOF
chmod 755 "$PKG_ROOT/DEBIAN/postrm"

# ── 12. Paket bauen ───────────────────────────────────────────────────────────
echo "=== Schritt 12: .deb bauen ==="

# Dateirechte prüfen
find "$PKG_ROOT/DEBIAN" -type f ! -name "control" ! -name "md5sums" -exec chmod 755 {} \;

echo "  Erstelle Paketarchiv; dpkg-deb kann während der Kompression kurz ohne Ausgabe laufen."
dpkg-deb --root-owner-group --build "$PKG_ROOT" "${APP_NAME}_${VERSION}_${ARCH}.deb"
sha256sum "${APP_NAME}_${VERSION}_${ARCH}.deb" > "${APP_NAME}_${VERSION}_${ARCH}.deb.sha256.tmp"
mv "${APP_NAME}_${VERSION}_${ARCH}.deb.sha256.tmp" "${APP_NAME}_${VERSION}_${ARCH}.deb.sha256"
sha256sum -c "${APP_NAME}_${VERSION}_${ARCH}.deb.sha256"

echo ""
echo "✓ Debian-Paket erfolgreich erstellt: ${APP_NAME}_${VERSION}_${ARCH}.deb"
echo "✓ SHA256: $(cut -d' ' -f1 "${APP_NAME}_${VERSION}_${ARCH}.deb.sha256")"
echo ""
echo "Paketinhalt (Zusammenfassung):"
dpkg-deb --contents "${APP_NAME}_${VERSION}_${ARCH}.deb" | awk '{print $NF}' | grep -E '\.(so|real|conf)$|/bin/|/plugins/' | sort | head -60
