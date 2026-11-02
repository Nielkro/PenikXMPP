#!/usr/bin/env bash
set -euo pipefail

# build_desktop.sh
# Builds the Penik Desktop client (DinoX fork) using the official containerized build environment.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DESKTOP_DIR="$REPO_ROOT/desktop"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. Determine container engine (podman preferred for rootless execution, fallback to docker)
CONTAINER_ENGINE=""
if command -v podman &>/dev/null; then
    CONTAINER_ENGINE="podman"
elif command -v docker &>/dev/null; then
    CONTAINER_ENGINE="docker"
else
    log_err "Neither podman nor docker found in PATH."
    log_err "Please install podman or docker to build the desktop client in a reproducible container."
    exit 1
fi

log_info "Using container engine: $CONTAINER_ENGINE"

BUILD_CONTAINER_IMAGE="git.dinox.im/dinoxim/linux-package-builder-dinox@sha256:5804b93b0bb1ca900470873e1de128f4e4e6ec634d5768f90399e3f756509230"
WEBRTC_ARCHIVE_URL="https://git.dinox.im/dinoxim/dinox/releases/download/vendor-deps/libwebrtc-m152-linux-x86_64-runtime-abi40-ipc10-sha256-2479cdb9ab7e.tar.gz"
WEBRTC_SHA256="2479cdb9ab7eace826e28d519a9dd33478329e34c303ed716c196005d9cec46f"

# Parse CLI options
RECONFIGURE=0
CLEAN=0
BUILD_APPIMAGE=0
RUN_APP=0

for arg in "$@"; do
    case "$arg" in
        --reconfigure) RECONFIGURE=1 ;;
        --clean) CLEAN=1 ;;
        --appimage) BUILD_APPIMAGE=1 ;;
        --run) RUN_APP=1 ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --reconfigure  Wipe build directory and re-run meson setup"
            echo "  --clean        Clean build targets before compiling"
            echo "  --appimage     Build self-contained AppImage bundle"
            echo "  --run          Launch the compiled binary inside container with GUI forwarding"
            echo "  -h, --help     Show this help"
            exit 0
            ;;
        *)
            log_err "Unknown option: $arg"
            exit 2
            ;;
    esac
done

# 2. Check / download Google/libwebrtc runtime
VENDOR_DEPS="$DESKTOP_DIR/.vendor-deps"
WEBRTC_DIR="$VENDOR_DEPS/libwebrtc-m152-linux-x86_64-runtime"
if [[ ! -d "$WEBRTC_DIR" ]]; then
    log_info "Google/libwebrtc M152 runtime not found in $VENDOR_DEPS. Downloading..."
    mkdir -p "$VENDOR_DEPS"
    curl -fsSL "$WEBRTC_ARCHIVE_URL" -o "$VENDOR_DEPS/libwebrtc-runtime.tar.gz"
    echo "$WEBRTC_SHA256  $VENDOR_DEPS/libwebrtc-runtime.tar.gz" | sha256sum -c -
    tar -xzf "$VENDOR_DEPS/libwebrtc-runtime.tar.gz" -C "$VENDOR_DEPS"
    log_ok "libwebrtc runtime extracted and verified."
fi

# 3. Setup or reconfigure meson build
BUILD_DIR="$DESKTOP_DIR/build"
if [[ $RECONFIGURE -eq 1 && -d "$BUILD_DIR" ]]; then
    log_info "Wiping existing build directory for reconfiguration..."
    rm -rf "$BUILD_DIR"
fi

CONTAINER_ENV=(
    -e PKG_CONFIG_PATH="/opt/dinox-deps/lib/pkgconfig"
    -e LD_LIBRARY_PATH="/opt/dinox-deps/lib"
    -e PATH="/opt/dinox-deps/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
)

if [[ ! -f "$BUILD_DIR/build.ninja" ]]; then
    log_info "Configuring Meson build..."
    $CONTAINER_ENGINE run --rm \
        -v "$DESKTOP_DIR:/workspace:Z" \
        -w /workspace \
        "${CONTAINER_ENV[@]}" \
        "$BUILD_CONTAINER_IMAGE" \
        meson setup build \
            --prefix=/usr \
            --buildtype=debugoptimized \
            -Dgoogle-libwebrtc-runtime-root=/workspace/.vendor-deps/libwebrtc-m152-linux-x86_64-runtime \
            -Dgoogle-libwebrtc-wrapper=enabled \
            -Dplugin-mqtt=enabled \
            -Ddnssec=enabled \
            -Dplugin-rtp=disabled \
            -Dplugin-google-webrtc=enabled
    log_ok "Meson setup completed."
fi

# 4. Compile with ninja
if [[ $CLEAN -eq 1 ]]; then
    log_info "Cleaning previous build..."
    $CONTAINER_ENGINE run --rm \
        -v "$DESKTOP_DIR:/workspace:Z" \
        -w /workspace \
        "${CONTAINER_ENV[@]}" \
        "$BUILD_CONTAINER_IMAGE" \
        ninja -C build clean
fi

if [[ $BUILD_APPIMAGE -eq 1 ]]; then
    log_info "Building standalone AppImage..."
    $CONTAINER_ENGINE run --rm \
        -v "$DESKTOP_DIR:/workspace:Z" \
        -w /workspace \
        "${CONTAINER_ENV[@]}" \
        "$BUILD_CONTAINER_IMAGE" \
        bash scripts/build-appimage.sh
    log_ok "AppImage created in $DESKTOP_DIR"
else
    log_info "Compiling desktop binary..."
    $CONTAINER_ENGINE run --rm \
        -v "$DESKTOP_DIR:/workspace:Z" \
        -w /workspace \
        "${CONTAINER_ENV[@]}" \
        "$BUILD_CONTAINER_IMAGE" \
        ninja -C build -j"$(nproc 2>/dev/null || echo 4)"
    log_ok "Build finished: $BUILD_DIR/main/dinox"
fi

# 5. Run if requested
if [[ $RUN_APP -eq 1 ]]; then
    log_info "Launching client with X11 forwarding..."
    $CONTAINER_ENGINE run --rm -it \
        -v "$DESKTOP_DIR:/workspace:Z" \
        -w /workspace \
        -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
        -e DISPLAY="${DISPLAY:-:0}" \
        "${CONTAINER_ENV[@]}" \
        "$BUILD_CONTAINER_IMAGE" \
        ./build/main/dinox
fi
