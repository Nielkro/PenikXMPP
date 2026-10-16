#!/usr/bin/env bash
set -euo pipefail

# install_phone.sh
# Builds and installs Penik (Conversations Free Debug) onto a connected Android device via ADB.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

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

# 1. Locate adb
ADB_BIN="$(command -v adb 2>/dev/null || true)"
if [[ -z "$ADB_BIN" ]]; then
    if [[ -n "${ANDROID_HOME:-}" && -x "$ANDROID_HOME/platform-tools/adb" ]]; then
        ADB_BIN="$ANDROID_HOME/platform-tools/adb"
    elif [[ -n "${ANDROID_SDK_ROOT:-}" && -x "$ANDROID_SDK_ROOT/platform-tools/adb" ]]; then
        ADB_BIN="$ANDROID_SDK_ROOT/platform-tools/adb"
    else
        log_err "adb not found in PATH or ANDROID_HOME/ANDROID_SDK_ROOT."
        log_err "Please install Android platform-tools or add adb to your PATH."
        exit 1
    fi
fi

# Parse options
NO_BUILD=0
NO_LAUNCH=0
DEVICE_SERIAL=""

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -s <serial>    Target specific ADB device serial"
    echo "  -n, --no-build Skip Gradle build and install existing APK"
    echo "  --no-launch    Do not launch the app after installation"
    echo "  -h, --help     Show this help message"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s)
            DEVICE_SERIAL="$2"
            shift 2
            ;;
        -n|--no-build)
            NO_BUILD=1
            shift
            ;;
        --no-launch)
            NO_LAUNCH=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_err "Unknown argument: $1"
            usage
            ;;
    esac
done

# 2. Check connected devices
log_info "Checking ADB devices..."
DEVICES=($("$ADB_BIN" devices | awk 'NR>1 && $2=="device" {print $1}'))

if [[ ${#DEVICES[@]} -eq 0 ]]; then
    log_err "No authorized Android devices found via ADB."
    log_err "Make sure:"
    log_err "  1. Phone is connected via USB."
    log_err "  2. USB debugging is turned ON in Developer Options."
    log_err "  3. Phone is unlocked and USB debugging prompt is accepted ('Always allow')."
    exit 1
fi

if [[ -n "$DEVICE_SERIAL" ]]; then
    FOUND=0
    for dev in "${DEVICES[@]}"; do
        if [[ "$dev" == "$DEVICE_SERIAL" ]]; then
            FOUND=1
            TARGET_DEV="$DEVICE_SERIAL"
            break
        fi
    done
    if [[ $FOUND -eq 0 ]]; then
        log_err "Specified device serial '$DEVICE_SERIAL' not found among connected devices: ${DEVICES[*]}"
        exit 1
    fi
else
    if [[ ${#DEVICES[@]} -eq 1 ]]; then
        TARGET_DEV="${DEVICES[0]}"
    else
        TARGET_DEV="${DEVICES[0]}"
        log_warn "Multiple devices detected: ${DEVICES[*]}. Picking first: $TARGET_DEV (use -s <serial> to choose)."
    fi
fi

MODEL=$("$ADB_BIN" -s "$TARGET_DEV" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || echo "Unknown device")
log_ok "Target device: $TARGET_DEV ($MODEL)"

# 3. Build APK
if [[ $NO_BUILD -eq 0 ]]; then
    log_info "Building Penik (assembleConversationsFreeDebug)..."
    bash ./gradlew assembleConversationsFreeDebug
    log_ok "Build finished successfully."
else
    log_info "Skipping build (--no-build specified)."
fi

# 4. Find generated APK
APK_PATH=$(find build/outputs/apk/conversationsFree/debug/ -type f -name "*.apk" 2>/dev/null | head -n 1 || true)
if [[ -z "$APK_PATH" || ! -f "$APK_PATH" ]]; then
    APK_PATH=$(find build/outputs/apk/ -type f -name "*Free-debug*.apk" 2>/dev/null | head -n 1 || true)
fi

if [[ -z "$APK_PATH" || ! -f "$APK_PATH" ]]; then
    log_err "Could not find built APK in build/outputs/apk/conversationsFree/debug/"
    exit 1
fi

log_info "Found APK: $APK_PATH"

# 5. Install APK
log_info "Installing APK to $TARGET_DEV ($MODEL)..."
"$ADB_BIN" -s "$TARGET_DEV" install -r -d "$APK_PATH"
log_ok "Installation completed successfully."

# 6. Launch App
if [[ $NO_LAUNCH -eq 0 ]]; then
    APP_PKG="ru.penik.xmpp"
    APP_ACTIVITY="eu.siacs.conversations.ui.ConversationActivity"
    log_info "Launching $APP_PKG/$APP_ACTIVITY..."
    "$ADB_BIN" -s "$TARGET_DEV" shell am start -n "$APP_PKG/$APP_ACTIVITY" >/dev/null
    log_ok "Application launched on device."
fi

log_ok "All done! Penik is installed and ready."
