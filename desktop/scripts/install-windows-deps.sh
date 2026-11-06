#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Initializing MSYS2 pacman keys..."
pacman-key --init
pacman-key --populate msys2

echo "==> Synchronizing active pacman package databases..."
pacman -Sy --noconfirm

echo "==> Installing available repository packages..."
pacman -S --needed --noconfirm \
  git curl tar unzip base-devel \
  mingw-w64-x86_64-toolchain \
  mingw-w64-x86_64-vala \
  mingw-w64-x86_64-meson \
  mingw-w64-x86_64-ninja \
  mingw-w64-x86_64-pkgconf \
  mingw-w64-x86_64-cmake \
  mingw-w64-x86_64-python \
  mingw-w64-x86_64-python-dnspython \
  mingw-w64-x86_64-python-cryptography \
  mingw-w64-x86_64-python-h2 \
  mingw-w64-x86_64-glib2 \
  mingw-w64-x86_64-glib-networking \
  mingw-w64-x86_64-gdk-pixbuf2 \
  mingw-w64-x86_64-libsoup3 \
  mingw-w64-x86_64-json-glib \
  mingw-w64-x86_64-icu \
  mingw-w64-x86_64-libgcrypt \
  mingw-w64-x86_64-gnupg \
  mingw-w64-x86_64-pinentry \
  mingw-w64-x86_64-gnutls \
  mingw-w64-x86_64-qrencode \
  mingw-w64-x86_64-libsecret \
  mingw-w64-x86_64-libyaml \
  mingw-w64-x86_64-libnice \
  mingw-w64-x86_64-gstreamer \
  mingw-w64-x86_64-gst-plugins-base \
  mingw-w64-x86_64-opus \
  mingw-w64-x86_64-openh264 \
  mingw-w64-x86_64-libvpx \
  mingw-w64-x86_64-protobuf-c \
  mingw-w64-x86_64-openssl \
  mingw-w64-x86_64-libarchive \
  mingw-w64-x86_64-librsvg \
  mingw-w64-x86_64-hicolor-icon-theme \
  mingw-w64-x86_64-adwaita-icon-theme \
  mingw-w64-x86_64-cantarell-fonts \
  mingw-w64-x86_64-unbound \
  mingw-w64-x86_64-go \
  mingw-w64-x86_64-cairo \
  mingw-w64-x86_64-graphene \
  mingw-w64-x86_64-libepoxy \
  mingw-w64-x86_64-vulkan-loader \
  mingw-w64-x86_64-shared-mime-info \
  mingw-w64-x86_64-fribidi \
  mingw-w64-x86_64-c-ares \
  mingw-w64-x86_64-cjson \
  mingw-w64-x86_64-libwebsockets \
  mingw-w64-x86_64-gtk-update-icon-cache

echo "==> Fetching archived MinGW64 packages pruned from current rolling database..."
DOWNLOAD_DIR="${RUNNER_TEMP:-/tmp}/msys2-archived-pkgs"
mkdir -p "$DOWNLOAD_DIR"

ARCHIVED_PACKAGES=(
  "mingw-w64-x86_64-libgee-0.20.8-2-any.pkg.tar.zst"
  "mingw-w64-x86_64-libsrtp-2.8.1-1-any.pkg.tar.zst"
  "mingw-w64-x86_64-mosquitto-2.0.22-2-any.pkg.tar.zst"
  "mingw-w64-x86_64-sqlcipher-4.6.1-2-any.pkg.tar.zst"
  "mingw-w64-x86_64-gpgme-1.23.2-17-any.pkg.tar.zst"
  "mingw-w64-x86_64-gst-plugins-bad-libs-1.28.8-1-any.pkg.tar.zst"
  "mingw-w64-x86_64-libxmlb-0.3.24-2-any.pkg.tar.zst"
  "mingw-w64-x86_64-appstream-1.0.6-3-any.pkg.tar.zst"
  "mingw-w64-x86_64-gtk4-4.18.6-4-any.pkg.tar.zst"
  "mingw-w64-x86_64-libadwaita-1.7.8-1-any.pkg.tar.zst"
  "mingw-w64-x86_64-gst-plugins-good-1.28.8-1-any.pkg.tar.zst"
  "mingw-w64-x86_64-gst-plugins-bad-1.28.8-1-any.pkg.tar.zst"
  "mingw-w64-x86_64-gst-plugins-ugly-1.28.8-1-any.pkg.tar.zst"
  "mingw-w64-x86_64-gst-libav-1.28.8-1-any.pkg.tar.zst"
)

REPO_BASE="https://repo.msys2.org/mingw/mingw64"
for pkg in "${ARCHIVED_PACKAGES[@]}"; do
  pkg_path="$DOWNLOAD_DIR/$pkg"
  if [ ! -s "$pkg_path" ]; then
    echo "Downloading $pkg..."
    curl -sSL -f -o "$pkg_path" "$REPO_BASE/$pkg"
  fi
  sig_path="$DOWNLOAD_DIR/$pkg.sig"
  if [ ! -s "$sig_path" ]; then
    curl -sSL -f -o "$sig_path" "$REPO_BASE/$pkg.sig" 2>/dev/null || true
  fi
done

echo "==> Installing archived MinGW64 packages via pacman -U..."
(
  cd "$DOWNLOAD_DIR"
  pacman -U --noconfirm --needed --nodeps --nodeps "${ARCHIVED_PACKAGES[@]}"
)

echo "==> Verifying toolchain and key packages..."
pkg-config --modversion gtk4
pkg-config --modversion libadwaita-1
pkg-config --modversion sqlcipher
pkg-config --modversion gee-0.8
test -s /mingw64/bin/libxmlb-2.dll || {
  echo "ERROR: AppStream runtime dependency libxmlb-2.dll was not installed!" >&2
  exit 1
}
vala --version
ninja --version
meson --version

echo "==> Verifying GStreamer plugins..."
test -f /mingw64/lib/gstreamer-1.0/libgstisomp4.dll || {
  echo "ERROR: Required GStreamer plugin libgstisomp4.dll (qtdemux) was not installed!" >&2
  exit 1
}
test -f /mingw64/lib/gstreamer-1.0/libgstvideoparsersbad.dll || {
  echo "ERROR: Required GStreamer plugin libgstvideoparsersbad.dll (h264parse) was not installed!" >&2
  exit 1
}

echo "All Windows dependencies installed successfully."
