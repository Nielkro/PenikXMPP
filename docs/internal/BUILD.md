# Building DinoX

This document describes the currently supported DinoX build paths.

The instructions below describe the version 2.3.3 build configuration.
The Windows guides in [English](WINDOWS_BUILD_EN.md) and
[German](WINDOWS_BUILD.md) cover both master rebuilds and release packages.
For an existing release tag, select that version in step 3B and follow steps
4–9. Section 10 is only for maintainers preparing a new version number.
[RELEASE_READINESS.md](RELEASE_READINESS.md) retains historical acceptance
records and release-recovery details.

DinoX is a GTK4/libadwaita XMPP client with OMEMO, OpenPGP, Tor/Lyrebird,
MQTT, location sharing, voice/video calls, voice messages and video messages.
Calls and microphone/camera capture use the pinned Google/libwebrtc worker
runtime: M152 on Linux and Windows. On Linux, the `ffmpeg` command
encodes and muxes captured message data;
on Windows, Windows Media Foundation does that work. GStreamer remains for
media-file demuxing, decoding, playback, thumbnails and metadata. It is not the
production call engine or Linux recorder muxer. Google/libwebrtc owns call
ICE, STUN and TURN. `libnice` remains a build/runtime dependency only because
the separate legacy ICE plugin also provides local-address discovery and
Tor/SOCKS5 policy hooks for direct Jingle-S5B file transfers.

## Supported Build Targets

| Target | Status | Notes |
|--------|--------|-------|
| Local Linux build | Reference | x86_64 only; Ubuntu 24.04 LTS, Linux Mint 22.x and Debian 13. |
| Ubuntu/Mint Debian-format package | Supported | amd64 only; built by `scripts/build-deb.sh` on Ubuntu 24.04 and supported on Ubuntu 24.04/Linux Mint 22.x. It is not a Debian 13 binary package. |
| AppImage | Supported | x86_64 only; built by `scripts/build-appimage.sh` and bundles selected runtime libraries and GStreamer plugins. |
| Flatpak | Supported | x86_64 only; built from `im.dinox.dinox.json` with GNOME Platform/Sdk 50. |
| Windows | Supported, needs separate guide | Built with MSYS2/MINGW64; see the Windows build guides below. |
| Ubuntu 26.04 | Planned verification | Treat as the next Ubuntu validation target before documenting it as supported. |
| Fedora / openSUSE / Arch source builds | Not supported here | These have not been fully verified for calls, voice messages and video messages. Platform media and package behavior still needs validation. |

## Current Reference Platform

Use a clean x86_64 Ubuntu 24.04 LTS, Linux Mint 22.x or Debian 13 system as the
supported Linux source-build baseline. Ubuntu 24.04 and Mint 22.x remain the
compatibility floor; Debian 13 is the current modern Debian target.

The published Google/libwebrtc Linux runtime currently has an x86_64 ABI and
its validation gate requires `target_cpu=x64`. Consequently, the documented
source build, `.deb`, AppImage and Flatpak paths are not supported on aarch64
yet. Do not substitute a differently built wrapper or worker without also
updating and passing the repository runtime gates.

The local reference build must work first. The Ubuntu/Mint `.deb`, AppImage and
Flatpak packages should then be compared against that behavior, especially for:

- account unlock and encrypted local databases
- legacy OMEMO; OMEMO 2 remains disabled in the production configuration
- OpenPGP
- file upload and previews
- voice messages
- video messages
- 1:1 audio/video calls
- Tor/Lyrebird
- MQTT plugin
- location sharing
- translations and locale startup

## General Requirements

libsoup 3.4 or newer is required. Tor bridge retrieval and WebTunnel health
checks use its per-message HTTP/1.1 API to avoid asynchronous HTTP/2 cleanup
warnings from short-lived sessions. HTTPS certificate validation still applies.
Ubuntu 24.04 and Linux Mint 22.x provide the supported libsoup 3.4 baseline;
the validated Windows runtime uses 3.6.6. The package and pkg-config module
remain named `libsoup-3.0-dev` and `libsoup-3.0` respectively.
DEB packages require `libsoup-3.0-0 (>= 3.4)` at installation. AppImage bundles
the build runtime library; Flatpak uses the library supplied by GNOME Runtime 50.

- GCC or Clang
- Meson and Ninja
- Vala
- GTK4 and libadwaita
- SQLCipher
- libunbound >= 1.19 for DNSSEC validation; ordinary DNS and TLS remain available when the per-account policy is off
- GStreamer core/base/good/bad/ugly/libav plugin sets for file demux/decode
- the `ffmpeg` command with AAC, H.264 (`libx264` or `libopenh264`) and MP4
  support for Linux voice/video-message output
- PipeWire, PulseAudio or ALSA device support as exposed through libwebrtc
- the published DinoX Google/libwebrtc platform runtime for calls, capture and
  decoded-audio output
- libnice, GnuTLS and libsrtp for the still-packaged legacy ICE plugin; its
  local-address and Tor/SOCKS5 policy hooks are also used by direct Jingle-S5B
  file transfer, while Google/libwebrtc handles call ICE/STUN/TURN
- libgcrypt and libsignal-protocol-c/libomemo-c for encryption
- GnuPG 2.4 command-line helpers (`gpg`, `gpgconf`, `gpg-agent`, `dirmngr` and
  `gpg-connect-agent`) for OpenPGP
- the `openssl` command for password-encrypted backup export and restore
- Go >= 1.22 only when building the optional Lyrebird transport locally

OpenPGP helpers run with DinoX's own user-data `GNUPGHOME`. Installing the
GnuPG programs on Linux supplies executables, not a shared system keyring.
Windows packages include the helpers and use the same application-scoped
keyring rule. Keep the complete helper set and its licenses in the package.

The Linux tray uses the existing GIO session-D-Bus dependency and the in-tree
SNI/DBusMenu exporter. It needs no external `libdbusmenu` library. Flatpak
retains `--talk-name=org.kde.StatusNotifierWatcher` for registration; the host
reads the exported menu and PNG icons through that connection. The native menu
background follows the desktop's theme. Windows uses Win32/GDI32, draws its
icons/menu with DinoX's light/dark choice and retains native high-contrast mode.

Official Debian and AppImage jobs use the prebuilt DinoX package-builder image.
`scripts/ci-build-deps.sh` is the root-level provisioning step for that
container image; it is not the recommended bootstrap command for a developer's
workstation.

DinoX prepares a small private IBus 1.5.30 client library as part of the Linux
source dependency setup and package builds. Only a system client identified as
`libibus-1.0.so.5.0.529` selects this correction, before GTK initializes IBus.
Newer, unknown or already loaded clients keep their normal library. The
correction retains synchronous input and does not replace the system daemon,
GTK input module, packages or settings. Explicit input-method and input-mode
settings remain in effect. Windows does not use this Linux correction.

`scripts/prepare-ibus-compat.sh` verifies the official source archive, builds
only the core client, and stores it below the private dependency prefix in
`lib/dinox/ibus-compat/`. It also retains the license and corresponding source.
The library is never put directly in a normal library search directory. Deb,
AppImage and Flatpak ship that private directory; source builds use the
prepared source dependency prefix. Running the dependency setup again reuses
the verified result. No PPA or additional system repository is needed.

## Linux Source Build

This is the shortest supported path for people who want to compile and run
DinoX themselves. The required path is linear:

1. install the normal distribution packages;
2. download and verify the small public Google/libwebrtc runtime;
3. configure and compile DinoX;
4. run `build/main/dinox`.

The Deb, AppImage, Flatpak, release and dependency-builder chapters are
optional and are not needed for a normal source-tree run. Lyrebird is optional
as well. Run all commands in a terminal and keep using the repository root
unless a command explicitly says otherwise.

On a fresh system, install Git and the CA certificates first. Debian minimal
installations may not contain `sudo`; in that case run the package commands as
`root` and omit `sudo`, then return to the normal desktop user before cloning,
building or starting DinoX. Never run DinoX itself with `sudo`.

```bash
sudo apt update
sudo apt install ca-certificates git
git clone https://git.dinox.im/dinoxim/dinox.git "$HOME/dinox"
cd "$HOME/dinox"
```

Confirm the supported CPU architecture and distribution before downloading
the x86_64-only runtime:

```bash
test "$(uname -m)" = x86_64 || {
  echo "This DinoX build path currently requires x86_64." >&2
  false
}
. /etc/os-release
printf 'Distribution: %s %s\n' "$ID" "$VERSION_ID"
case "$ID:$VERSION_ID" in
  ubuntu:24.04|debian:13|linuxmint:22*) ;;
  *)
    echo "Unsupported source-build baseline: $ID $VERSION_ID" >&2
    false
    ;;
esac
```

The commands below build the current `master`. A release tag must be built
with the build guide and scripts contained in that same tag. Do not check out
an older tag and then continue with commands copied from the current `master`
guide; older tags can predate required helpers or use a different dependency
baseline.

### Ubuntu 24.04 / Linux Mint 22.x / Debian 13

On Ubuntu 24.04, enable the official `universe` component first. Linux Mint
22.x already enables the corresponding Ubuntu components. Do not run this
Ubuntu-specific command on Debian:

```bash
if grep -q '^ID=ubuntu$' /etc/os-release; then
  sudo apt install software-properties-common
  sudo add-apt-repository -y universe
  sudo apt update
fi
```

Install the build and runtime packages:

```bash
sudo apt update
sudo apt install \
  binutils \
  build-essential \
  ca-certificates \
  cmake \
  curl \
  dirmngr \
  file \
  git \
  gettext \
  iso-codes \
  gpg \
  gpg-agent \
  gpgconf \
  meson \
  ninja-build \
  openssl \
  pkg-config \
  python3 \
  python3-dnspython \
  python3-cryptography \
  python3-h2 \
  tar \
  valac \
  wget \
  xz-utils \
  tcl \
  libadwaita-1-dev \
  libcanberra-dev \
  libcjson-dev \
  libgee-0.8-dev \
  libgeoclue-2-dev \
  libgcrypt20-dev \
  libglib2.0-dev \
  libgnutls28-dev \
  libunbound-dev \
  libgpgme-dev \
  libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev \
  libgstreamer-plugins-bad1.0-dev \
  libgtk-4-dev \
  libicu-dev \
  libjson-glib-dev \
  libmosquitto-dev \
  libnice-dev \
  libnotify-dev \
  libqrencode-dev \
  libreadline-dev \
  libsecret-1-dev \
  libsoup-3.0-dev \
  libsqlite3-dev \
  libsqlcipher-dev \
  sqlcipher \
  libssl-dev \
  libsrtp2-dev \
  libunwind-dev \
  libva-dev \
  libva-drm2 \
  libva-x11-2 \
  heif-gdk-pixbuf \
  webp-pixbuf-loader \
  libheif-plugin-dav1d \
  ffmpeg \
  geoclue-2.0 \
  gstreamer1.0-alsa \
  gstreamer1.0-libav \
  gstreamer1.0-pipewire \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-ugly \
  gstreamer1.0-tools \
  gstreamer1.0-vaapi \
  xauth \
  xvfb
```

Package names above are the Debian-family baseline. If a distribution package
is unavailable, build that dependency from its upstream source into a dedicated
prefix. Do not run `scripts/ci-build-deps.sh` on a normal workstation: it
installs pinned package-only dependencies into the isolated
`/opt/dinox-deps` prefix, expects root/container semantics and also prepares
the release Tor/Lyrebird versions.

Verify every Linux message-writer capability before configuring DinoX. All
four commands must print a matching line:

```bash
ffmpeg -hide_banner -encoders 2>/dev/null | grep -E ' aac[[:space:]]'
ffmpeg -hide_banner -encoders 2>/dev/null | grep -E ' (libx264|libopenh264)[[:space:]]'
ffmpeg -hide_banner -muxers 2>/dev/null | grep -E ' ipod[[:space:]]'
ffmpeg -hide_banner -muxers 2>/dev/null | grep -E ' mp4[[:space:]]'
```

### Prepare the pinned Linux source-build dependencies

Normal DinoX source builds use the same public dependency versions as the
official packages: protobuf-c 1.5.2, libomemo-c 0.5.1 and the Google/libwebrtc
M152 Linux runtime. Ubuntu 24.04's libomemo-c 0.5.0 and protobuf-c 1.4.1 packages are
deliberately not used. The helper installs the two small encryption libraries
and the private IBus client correction below the checkout without root
privileges and downloads the prebuilt WebRTC runtime; it does not build
Chromium/WebRTC locally.

The pinned runtime uses wrapper ABI 40, control IPC 10 and video ring 6. It
also includes `dinox-vision-worker`, the two exact models under
`dinox-vision-models`, their original license texts and a hash-bound manifest.
These files are installed together beside the private WebRTC library and work
offline; no model download is needed during a call. The WebRTC M152 SDK and
codec source pin are unchanged; this update adds DinoX's effect and inference
code. Do not copy only the `.so` from another runtime.

See [runtime packaging](GOOGLE_WEBRTC_RELEASE_PACKAGING.md) for the separate
inference source recipe, runtime layout and acceptance limits. Native Windows
runtime and tray probes have passed; the complete current Windows application
build-log review and physical call/device acceptance remain separate release
gates. A source build alone does not complete those gates.

```bash
bash scripts/prepare-linux-source-build-deps.sh
```

The three archives are published at the public
[`vendor-deps`](https://git.dinox.im/dinoxim/dinox/releases/tag/vendor-deps)
release; the WebRTC archive also has a convenience sidecar. The hashes pinned
in the helper are the trust anchors; mutable sidecars alone are not. Re-running
the command validates and reuses complete dependencies and replaces corrupt
downloads. The additional IBus source is downloaded from the official Ubuntu
release archive with its own pinned SHA-256; its client library is built with
one compiler job and the temporary build directory is removed afterwards.

### Configure, build and run

This block is self-contained even in a newly opened terminal. It validates the
runtime again, writes a fresh production configuration and builds the fixed
`build/` tree. The normal user build reports warnings but does not fail only
because a distribution compiler emits one; contributors and release
maintainers use `--strict`.

```bash
(
  set -e
  vendor_root_input="${DINOX_LINUX_VENDOR_ROOT:-$PWD/.vendor-deps}"
  vendor_root="$(cd "$vendor_root_input" && pwd -P)"
  runtime_root="$vendor_root/libwebrtc-m152-linux-x86_64-runtime"
  encryption_root="$vendor_root/linux-source-deps"
  ./scripts/check-libwebrtc-linux-runtime.sh "$runtime_root"
  export PKG_CONFIG_PATH="$encryption_root/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  meson setup --wipe --prefix=/usr --buildtype=debugoptimized build \
    -Dlocal-libomemo-c-root="$encryption_root" \
    -Dplugin-mqtt=enabled \
    -Ddnssec=enabled \
    -Dplugin-rtp=disabled \
    -Dplugin-google-webrtc=enabled \
    -Dgoogle-libwebrtc-wrapper=enabled \
    -Dgoogle-libwebrtc-runtime-root="$runtime_root" \
    -Dgoogle-libwebrtc-test-oracle=false \
    -Dgoogle-libwebrtc-tests=false \
    -Dlocation-sharing=enabled \
    -Dplugin-http-files=enabled \
    -Dplugin-ice=enabled \
    -Dplugin-omemo=enabled \
    -Dplugin-openpgp=enabled \
    -Dplugin-notification-sound=enabled
  ./scripts/build.sh
)
```

Native source builds, Deb packages and AppImages use the same normal profile
below `~/.local/share/dinox`. Fully quit any already running native, Deb or
AppImage DinoX instance, including its background/tray process, before this
first start; otherwise the existing single-instance application may merely be
activated instead of the binary that was just built. Do not run two of them at
the same time. Back up that profile before testing an older release or an
incompatible development branch. Flatpak uses its separate sandboxed profile
documented below.

Then confirm the built version and start the build-tree executable directly.
For Tor, prepare the [optional private runtime](#optional-private-tor-runtime)
once before enabling it. No system Tor or `PATH` fallback is required:

```bash
./build/main/dinox --version
DINOX_TOR_DATA_DIR="$PWD/.vendor-deps/linux-tor-runtime/share/tor" ./build/main/dinox
```

The build-tree run does not install DinoX system-wide. Keep the prepared Tor,
WebRTC and encryption dependency directories at their configured absolute paths.
Deleting or moving
the WebRTC runtime breaks calls and audio/video messages; deleting or moving
`linux-source-deps` breaks OMEMO loading in the build-tree executable. The
entire `.vendor-deps/` directory is ignored by Git. Run
`scripts/prepare-linux-source-build-deps.sh` and the full Meson configuration
block again after moving the checkout.

To inspect the configured plugins:

```bash
meson configure build | grep -E 'plugin|location'
```

The following local checks require only the configured build and repository
files:

```bash
./scripts/package-runtime-matrix.sh system
./scripts/package-runtime-matrix.sh flatpak-manifest im.dinox.dinox.json
./scripts/package-runtime-matrix.sh metadata
./scripts/package-runtime-matrix.sh self-test
```

`system` checks the local executable, every required production Meson option,
the validated Google/libwebrtc runtime root, the built plugin and host
FFmpeg/GStreamer availability. It now rejects legacy RTP or otherwise
misconfigured build trees; it is not a substitute for an installed-package
test. `local` is an alias for `system`. Run artifact-specific matrix modes only
after that artifact exists, as shown in the package sections below.

The complete Meson suite is optional for merely starting a local build. Run it
before contributing or preparing a release:

```bash
./scripts/run_all_tests.sh --meson
```

That runner performs another strict compile and uses the project's extended
test timeout and serialized test policy. The package list above includes
`xvfb`; without `xvfb-run`, Meson silently omits the GTK runtime test.

### Update an existing source build

First update the checkout without creating a merge commit:

```bash
cd "$HOME/dinox"
git pull --ff-only
```

Then repeat [the pinned dependency preparation](#prepare-the-pinned-linux-source-build-dependencies)
and [the production configure/build block](#configure-build-and-run). Repeating
both steps is deliberately conservative: a new DinoX revision may pin a new
runtime hash, ABI or Meson option. Start it again with:

```bash
DINOX_TOR_DATA_DIR="$PWD/.vendor-deps/linux-tor-runtime/share/tor" ./build/main/dinox
```

### Optional private Tor runtime

For local Tor use, including obfs4 and WebTunnel bridges, explicitly run
[`prepare-linux-tor-runtime.sh`](../../scripts/prepare-linux-tor-runtime.sh).
It builds Tor 0.4.9.12 and Lyrebird 0.8.1 from the same SHA-256-pinned Forgejo
archives as the package builder, without using system Tor or installing into
`/usr`. The equivalent canonical build command is `./scripts/build.sh --prepare-tor --strict`.
Normal builds do not download or rebuild Tor helpers automatically.

Requirements: a C compiler and make, pkg-config, libevent/OpenSSL/zlib development
files, Go >= 1.22, Python 3, curl, tar, ldd and flock. On Debian/Ubuntu:

```bash
sudo apt install build-essential pkg-config libevent-dev libssl-dev zlib1g-dev golang-go curl util-linux
bash scripts/prepare-linux-tor-runtime.sh
```

The helper runs as your normal user and never installs those prerequisites
itself. Go must support the pinned source's module directive; automatic Go
toolchain and module downloads are disabled. Compilation uses at most two jobs.
The private runtime is stored outside the Meson build tree, so `meson setup
--wipe` and clean application builds do not remove it. Only these local outputs
are installed:

```text
.vendor-deps/linux-tor-runtime/bin/tor
.vendor-deps/linux-tor-runtime/bin/lyrebird
.vendor-deps/linux-tor-runtime/share/tor/geoip
.vendor-deps/linux-tor-runtime/share/tor/geoip6
.vendor-deps/linux-tor-runtime/dinox-tor-runtime.json
```

Existing helpers remain untouched until the replacement passes version,
library and data checks. Unrelated files in the private runtime prefix are preserved. Installation
errors restore the previous files; interrupted transaction directories are
retained and must be inspected before another attempt. No Tor connection is
started and no account, proxy or bridge settings are changed.

Preparation verifies the pinned versions and file hashes before reusing an
existing runtime; an intact matching runtime is not rebuilt. Repeat the
preparation when its Tor/Lyrebird pins change. The direct
`build/main/dinox` executable discovers these private helpers even from another
working directory. Pin the matching GeoIP directory when starting:

```bash
DINOX_TOR_DATA_DIR="$PWD/.vendor-deps/linux-tor-runtime/share/tor" ./build/main/dinox
```

Automatic lookup applies to build directories directly below the repository.
For a build directory outside the repository, explicitly set `DINOX_TOR_PATH`,
`DINOX_LYREBIRD_PATH` and `DINOX_TOR_DATA_DIR` to the prepared private runtime.

If enabling WebTunnel in a source build reports `no lyrebird executable was
found`, run `bash scripts/prepare-linux-tor-runtime.sh`, then enable Tor again.
A system-wide Lyrebird installation alone does not satisfy this build's
private-runtime lookup. The subsequent `Tor start failed` message is the result
of that missing helper. Confirm that both `.vendor-deps/linux-tor-runtime/bin/tor` and
`.vendor-deps/linux-tor-runtime/bin/lyrebird` exist and are executable. Deb, AppImage and
Flatpak packages include their own helpers; this preparation step applies to
running directly from the source build.

The small offline regression check does not download or compile anything:

```bash
bash scripts/prepare-linux-tor-runtime.sh --self-test
```

## Ubuntu 24.04 / Linux Mint 22 Debian-format Package

`scripts/build-deb.sh` is an official package-builder entry point, not a
workstation bootstrap script. Besides the validated libwebrtc runtime, it
requires the pinned private dependencies under `/opt/dinox-deps`. Run it only
inside the current DinoX package-builder image. The two verification commands
below intentionally fail if the image is stale or incomplete. A working Docker
Engine and access to the public DinoX container registry are required:

The commands read the immutable builder-image digest from this checkout's
workflow. This keeps local package builds on the same dependency baseline as
Forgejo, including when building an older release with its own guide.

```bash
(
  set -e
  runtime_root="$PWD/.vendor-deps/libwebrtc-m152-linux-x86_64-runtime"
  test -d "$runtime_root"
  ./scripts/check-libwebrtc-linux-runtime.sh "$runtime_root"
  builder_image="$(python3 -c 'import re; from pathlib import Path; print(re.search(r"image: (git\.dinox\.im/dinoxim/linux-package-builder-dinox@sha256:[0-9a-f]{64})", Path(".github/workflows/build.yml").read_text()).group(1))')"
  docker pull "$builder_image"
  docker run --rm \
    --cpus=2 -e DINOX_BUILD_JOBS=2 \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp/dinox-home \
    -v "$PWD:/work" -w /work \
    -e DINOX_LIBWEBRTC_RUNTIME_ROOT=/work/.vendor-deps/libwebrtc-m152-linux-x86_64-runtime \
    "$builder_image" \
    bash -lc '
      bash scripts/verify-package-builder-for-package-job.sh &&
      bash scripts/verify-ci-deps.sh &&
      ./scripts/build-deb.sh --strict
    '
)
```

The script configures a fresh optimized `build-deb-package/` tree, compiles it
once, and checks that same tree with the local runtime matrix before installing
into `pkg_dinox/`. `--strict` rejects compiler warnings. It does not reuse a
workstation's `build/` directory or compile again during installation. It then
bundles the private runtime pieces and creates:

```text
dinox_<version>_amd64.deb
dinox_<version>_amd64.deb.sha256
```

The package version is read from the root `VERSION` file. This binary package
uses the Ubuntu 24.04 ABI baseline, including ICU 74, and is supported on
Ubuntu 24.04 and Linux Mint 22.x. Debian 13 uses ICU 76 and must not be claimed
as compatible with this binary; use the AppImage, Flatpak or a native Debian 13
source build there.

Verify the exact package, inspect its runtime matrix, install it with dependency
resolution and start it:

```bash
DEB_FILE="dinox_$(cat VERSION)_amd64.deb"
test -f "$DEB_FILE"
sha256sum -c "${DEB_FILE}.sha256"
./scripts/package-runtime-matrix.sh deb "$DEB_FILE"
sudo apt install "./$DEB_FILE"
dinox
```

## AppImage

The package targets x86_64 Linux with the Ubuntu 24.04/Mint 22 ABI floor. It is
not restricted to Debian-family distributions. GTK, GLib, GStreamer and their
in-process modules are bundled together; changing the host's versions must not
make DinoX load incompatible modules. libcanberra is built privately with a
relocatable module path. Its pinned Ubuntu sources, patch recipe and licenses
are included in the existing corresponding-source workflow.

The host still supplies glibc/toolchain ABIs, display and audio-driver interfaces,
the font stack and the current CA trust store. AppImage is not a container or a
sandbox: desktop services, user configuration and explicitly configured hardware
security providers remain host integrations. Do not bundle graphics drivers or
disable certificate checks to hide an incompatibility. Runtime checks on Ubuntu,
Debian and a different distribution family are described in [TESTING.md](TESTING.md).

`scripts/build-appimage.sh` is also restricted to the verified package-builder
image. It creates the `AppDir`, stages all private dependencies, performs the
license/source gates and then invokes the pinned `appimagetool`:

```bash
(
  set -e
  runtime_root="$PWD/.vendor-deps/libwebrtc-m152-linux-x86_64-runtime"
  test -d "$runtime_root"
  ./scripts/check-libwebrtc-linux-runtime.sh "$runtime_root"
  builder_image="$(python3 -c 'import re; from pathlib import Path; print(re.search(r"image: (git\.dinox\.im/dinoxim/linux-package-builder-dinox@sha256:[0-9a-f]{64})", Path(".github/workflows/build.yml").read_text()).group(1))')"
  docker pull "$builder_image"
  # Prepare the extra runtime modules in a disposable image, not on the host.
  # The inherited APT configuration uses the verified builder's snapshot.
  docker build --build-arg BASE_IMAGE="$builder_image" \
    -t dinox-appimage-builder-local - <<'DOCKERFILE'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
RUN gtk_version="$(dpkg-query -W -f='${Version}' libgtk-4-1)" && \
    apt-get update && apt-get install -y --no-install-recommends \
      "libgtk-4-media-gstreamer=$gtk_version" \
      glib-networking dconf-gsettings-backend gvfs gsettings-desktop-schemas \
      libheif-plugin-dav1d libheif-plugin-libde265 sound-theme-freedesktop \
      libpulse-dev libasound2-dev libvorbis-dev libtdb-dev libltdl-dev
DOCKERFILE
  docker run --rm \
    --cpus=2 -e DINOX_BUILD_JOBS=2 \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp/dinox-home \
    -v "$PWD:/work" -w /work \
    -e DINOX_LIBWEBRTC_RUNTIME_ROOT=/work/.vendor-deps/libwebrtc-m152-linux-x86_64-runtime \
    dinox-appimage-builder-local \
    bash -lc '
      bash scripts/verify-package-builder-for-package-job.sh &&
      bash scripts/verify-ci-deps.sh &&
      ./scripts/build-appimage.sh
    '
)
```

It writes the AppImage, its matching SHA-256 checksum and the mandatory
corresponding-source sidecar:

```text
DinoX-<version>-x86_64.AppImage
DinoX-<version>-x86_64.AppImage.sha256
DinoX-<version>-x86_64.AppImage.sources.tar.xz
DinoX-<version>-x86_64.AppImage.sources.tar.xz.sha256
```

The runnable AppImage contains all staged project and third-party license
material, the file-to-package inventory and a hash-pinned source-offer
manifest, but not the large corresponding-source archive payloads. The sidecar
contains the identical non-payload compliance tree plus the exact Ubuntu source
packages, recorder FFmpeg/x264 sources and Google/libwebrtc compliance payload.
The package build verifies the full pre-split tree, removes only inventoried
source payloads, verifies the slim AppDir and then cross-checks the sidecar
against the final AppDir. Missing, additional or changed payloads fail the
build.

Forgejo Actions exposes the runnable AppImage plus checksum as
`dinox-appimage`. The large corresponding-source files are a second,
independently downloadable `dinox-appimage-corresponding-sources` artifact.
Both artifacts use the same retention period. Release pages likewise publish
the AppImage and source sidecar as separate assets, so installing or testing
DinoX never requires downloading the source archive.

Verify and run the AppImage from the repository root:

```bash
APPIMAGE_FILE="DinoX-$(cat VERSION)-x86_64.AppImage"
test -f "$APPIMAGE_FILE"
sha256sum -c "${APPIMAGE_FILE}.sha256"
chmod +x "$APPIMAGE_FILE"
./"$APPIMAGE_FILE"
```

The corresponding-source sidecar is not required to run DinoX. If it was
downloaded for a compliance or release audit, verify it separately:

```bash
if [ -f "${APPIMAGE_FILE}.sources.tar.xz" ] \
    && [ -f "${APPIMAGE_FILE}.sources.tar.xz.sha256" ]; then
  sha256sum -c "${APPIMAGE_FILE}.sources.tar.xz.sha256"
fi
```

AppImage normally uses FUSE. On a host without a working FUSE mount helper,
use the built-in extraction fallback:

```bash
APPIMAGE_EXTRACT_AND_RUN=1 ./"$APPIMAGE_FILE"
```

Forgejo also rejects unexpectedly oversized installable artifacts before
uploading them: DEB is limited to 160 MiB, AppImage to 256 MiB and Flatpak to
512 MiB. These are product-size regression ceilings, not limits for the
separate corresponding-source artifact. A deliberate package growth must be
reviewed before changing the ceiling in `.github/workflows/build.yml`.
The M152 DEB includes its codec and hardware-provider source archives and
measured about 137 MiB in Forgejo run 259; its 160 MiB ceiling allows this
payload while retaining a bound on unexpected growth.

Other custom-built dependencies are represented by their complete staged
license trees and `METADATA` with a public, checksum-pinned source URL; their
source archives are not duplicated in this sidecar and must remain available at
those URLs. The matching DinoX source is provided by the Forgejo release
tag/source archive.

The corresponding runtime-matrix modes are:

```text
appdir-full        full pre-split AppDir, including source payloads
appdir             final slim AppDir with source-offer metadata
appdir-provenance  final AppDir plus extracted source sidecar
```

Notes:

- Use a clean build host or container for reproducible results.
- The Forgejo AppImage job has a 180-minute deadline, including up to 30 minutes
  for the final extraction, dependency and source-provenance checks and 20
  minutes for the isolated Debian 13 runtime check. Run 264 needed about 95
  minutes to produce the AppImage, then hit the former 10-minute limit during
  final verification. `scripts/test-package-workflow-budgets.py` checks that
  the workflow leaves room for the build, both checks and artifact uploads.
  These limits are ceilings, not expected build durations. Only a completed
  workflow verifies the resulting package; offline workflow checks do not.
- The AppImage intentionally consumes the stable host ABI for glibc and the
  compiler runtime plus X11, Wayland, font, audio and graphics libraries. These
  libraries are the explicit blacklist in `scripts/build-appimage.sh` and the
  matching AppImage allowlist in `scripts/package-runtime-matrix.sh`; a
  command-line-only Debian base without a desktop ABI is therefore not a valid
  AppImage runtime host.
- Forgejo first runs the static AppDir dependency-closure and provenance gates.
  It then builds `ci/images/appimage-runtime-gate/Dockerfile`, whose Debian 13
  base image is pinned by digest. The image extracts only the packages listed
  in `ci/images/appimage-runtime-gate/packages.txt`, without installing their
  dependency closure. This avoids adding a full desktop that would mask missing
  AppDir libraries; the preceding static All-ELF closure remains authoritative
  for libraries already present in the minimal Debian base. The final AppImage
  is copied into that container and run as an unprivileged user with
  `--network none`; the gate verifies the exact DinoX version and starts and
  cleanly stops the bundled GnuPG 2.4 agent and dirmngr through the relocatable
  `gpgconf`.
- This isolated check is a headless package-startup and helper-lifecycle gate,
  not a replacement for interactive display, audio, camera and call tests on a
  real desktop.
- The official workflow downloads `appimagetool` and `runtime-x86_64` from the
  DinoX Forgejo `vendor-deps` release assets and verifies both against hashes
  pinned in the repository. There is no network fallback to an unpinned runtime.
- Set `APPIMAGE_RUNTIME_FILE=/path/to/runtime-x86_64` together with
  `APPIMAGE_RUNTIME_SHA256=<hash>` (or a matching adjacent `.sha256` file) to
  force a specific local AppImage runtime file.
- To prepare or upload the mirrored runtime assets, use `scripts/mirror-appimage-runtimes.sh` or `scripts/mirror-appimage-runtimes.sh --upload`.
- A downloaded `runtime-*.sha256` sidecar must itself agree with the repository
  pin before the runtime is accepted.
- AppImage behavior depends on the bundled media decoders and on host services
  such as D-Bus and device access. The package must not depend on host-installed
  GStreamer plugins or a host `ffmpeg` command for supported message formats.

## Flatpak

The Flatpak manifest is:

```text
im.dinox.dinox.json
```

Current baseline:

- GNOME Platform/Sdk 50
- Freedesktop 25.08 SDK extension/runtime extensions used by the manifest
- DinoX app id: `im.dinox.dinox`
- translations are included in the main app
- SQLCipher is built with FTS5 enabled
- the pinned Google/libwebrtc Linux runtime is downloaded by the manifest
- OMEMO and media-file dependencies are built or provided through the
  runtime/manifest
- MQTT, Tor/Lyrebird and location sharing are enabled in the DinoX module
- codec/runtime behavior must be checked from inside the sandbox

For a local build, install the refs used by the Forgejo builder image and build
the bundle from the repository root:

The manifest copies the current working-tree sources, including uncommitted
changes. Its directory source has an explicit `skip` list for known local build,
cache and package paths, including the Flatpak bundle and its checksum, so these
outputs are not copied into the Flatpak build. Flatpak matches these paths exactly;
`.gitignore`, `.dockerignore` and glob patterns such as `build*` do not provide this
filtering. Keep generated output in the listed directories (for example `build`
or `dist`), or add its exact relative path to `skip`. Source directories such as
`build-aux` remain included.

```bash
(
  set -e
  sudo apt update
  sudo apt install flatpak flatpak-builder
  ./scripts/package-runtime-matrix.sh flatpak-manifest im.dinox.dinox.json
  flatpak remote-add --user --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo
  flatpak install --user flathub \
    runtime/org.gnome.Platform/x86_64/50 \
    runtime/org.gnome.Sdk/x86_64/50 \
    runtime/org.gnome.Sdk.Locale/x86_64/50 \
    runtime/org.freedesktop.Platform.GL.default/x86_64/25.08 \
    runtime/org.freedesktop.Platform.GL.default/x86_64/25.08-extra \
    runtime/org.freedesktop.Platform.codecs-extra/x86_64/25.08-extra \
    runtime/org.freedesktop.Sdk.Extension.golang/x86_64/25.08

  flatpak-builder --user --force-clean --repo=local-dino-repo \
    --arch=x86_64 \
    --default-branch=master flatpak-build im.dinox.dinox.json
  flatpak build-bundle local-dino-repo im.dinox.dinox.flatpak \
    --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo \
    --arch=x86_64 \
    im.dinox.dinox master
  sha256sum im.dinox.dinox.flatpak > im.dinox.dinox.flatpak.sha256
  sha256sum -c im.dinox.dinox.flatpak.sha256
)
```

Install, validate and start the local result:

```bash
flatpak install --user --noninteractive --reinstall ./im.dinox.dinox.flatpak
flatpak info --user im.dinox.dinox
flatpak run --user --command=dinox im.dinox.dinox --version
flatpak run --user --env=TMPDIR=/tmp \
  --command=/app/libexec/dinox-flatpak-runtime-gate \
  im.dinox.dinox layout
flatpak run --user --env=TMPDIR=/tmp \
  --command=/app/libexec/dinox-flatpak-runtime-gate \
  im.dinox.dinox writer
flatpak run --user --command=sh im.dinox.dinox -c \
  "for element in uridecodebin appsink qtdemux matroskademux; do gst-inspect-1.0 \"\$element\" >/dev/null || exit 1; done"
flatpak run --user --command=sh im.dinox.dinox -c \
  "ffmpeg -hide_banner -encoders 2>/dev/null | grep -E ' aac[[:space:]]' &&
   ffmpeg -hide_banner -encoders 2>/dev/null | grep -E ' (libx264|libopenh264)[[:space:]]' &&
   ffmpeg -hide_banner -muxers 2>/dev/null | grep -E ' ipod[[:space:]]' &&
   ffmpeg -hide_banner -muxers 2>/dev/null | grep -E ' mp4[[:space:]]'"
flatpak run --user im.dinox.dinox
```

Flatpak data paths are sandboxed by design:

```text
Data and databases: ~/.var/app/im.dinox.dinox/data/dinox
Configuration:      ~/.var/app/im.dinox.dinox/config/dinox
Cache:              ~/.var/app/im.dinox.dinox/cache/dinox
```

### DNSSEC, feeds and login-protection dependencies

`libunbound-dev` is required for supported Linux package builds. The Ubuntu
DEB declares `libunbound8 (>= 1.19)`; AppImage bundles its library closure;
Flatpak builds pinned Unbound inside the GNOME 50 SDK and uses the SDK's Expat
headers/library (`--with-libexpat=/usr`). Do not remove this configure option
or strip the pinned Vision worker: its manifest validates the original bytes.
The Linux package-builder image already contains Unbound and is verified by
`scripts/verify-package-builder-image.sh`; changing only application/docs code
does not require rebuilding either builder image.

The Python `dnspython`, `cryptography` and `h2` packages are for local DNSSEC,
TLS and SOCKS5 fixtures, not application runtime dependencies. SASL TLS tests
also use the existing `openssl` executable. Feeds reuse libsoup and libxml2;
no browser engine or always-on feed daemon is bundled. RSS/Atom subscriptions
send while DinoX runs and the account is connected. See [Feeds](FEEDS.md),
[DNSSEC/DANE](DNSSEC_DANE_PLAN.md) and [login protection](SASL_SECURITY.md).

## Windows

DinoX can be built on Windows 10 version 1903 or newer and on Windows 11
using MSYS2 with the MINGW64 toolchain. Windows is intentionally kept as a
supported target because audio/video calls and audio/video messages have
worked well there.

Use the dedicated guides:

- [WINDOWS_BUILD.md](WINDOWS_BUILD.md)
- [WINDOWS_BUILD_EN.md](WINDOWS_BUILD_EN.md)

For a Windows package from an existing tag, start with
[step 3B](WINDOWS_BUILD_EN.md#3b-build-a-particular-release-version), then follow
steps 4–9 for building, testing, ZIP creation and upload. To prepare a new
version number that has no tag yet, use the separate
[maintainer procedure](WINDOWS_BUILD_EN.md#10-publish-a-new-version-as-a-project-maintainer).

Short overview for building the development version:

1. Install MSYS2 and open the MINGW64 shell. Fully update a fresh public
   installation; do not update the frozen release VM without a separate
   baseline validation. All commands run as the same normal Windows user
   without Administrator or root privileges. Repository, vendor dependencies,
   build, and result use paths below that user's `$HOME`; MSYS2 supplies its
   toolchain and runtime below `/mingw64`.
2. Install the packages listed in the Windows guide and clone DinoX below the
   current MSYS2 user's `$HOME`. For an existing checkout, follow the dedicated
   guide's fetch-refspec and upstream commands and verify that `HEAD` exactly
   matches `origin/master`; a bare `git pull` is not accepted as proof.
3. Run `bash "$HOME/dinox/scripts/prepare-windows-build-deps.sh"` from any
   directory. It prepares the complete Pango `1.56.4-3` set, Tor 0.4.9.12,
   libomemo-c 0.5.1, Lyrebird 0.8.1 and the pinned Google/libwebrtc runtime
   from checked public inputs.
4. Run `bash "$HOME/dinox/scripts/build-windows-dist.sh"` from any directory.
   This command must finish its mandatory `check-windows-dist.sh` stage; the
   checker loads and registers all nine packaged plugins and requires every
   catalog from the three `LINGUAS` files, currently 84 in total.
5. Test the complete `$HOME/dinox/dist/` tree only after the native WebRTC,
   GnuPG-helper, translation, GTK/GStreamer startup and portable-DLL gates have
   passed. Only fully maintained languages are offered; unsupported language
   choices fall back to the English source strings.
6. To distribute the tested build, create the ZIP and checksum using step 8
   of the dedicated guide. Keep `dist/` together;
   copying only `dinox.exe` is not a portable distribution. The dedicated
   guides explain complete build logs and the separate release-commit checks.

Windows-specific notes:

- Interface text uses the native Windows font with a readable 11-point minimum
  and pixel-aligned font metrics. Larger system fonts remain unchanged.
  On GTK 4.16 and newer, DinoX selects manual font rendering so its hinting
  settings take effect. Display font resolution remains controlled by GDK;
  the package must not force 96 DPI. Chat font preferences remain separate.
- Tor and Lyrebird are bundled; Lyrebird provides obfs4 and WebTunnel.
- GeoClue2 location sharing is not available on Windows.
- libcanberra notification sounds are Linux-only.
- `dinox.exe` sets the required runtime paths internally; no batch launcher is
  part of the supported distribution.

## Unsupported Linux Source Build Notes

Fedora, openSUSE and Arch are not documented as supported source-build targets at the moment.

The main blocker is not compiling the UI. The critical part is validating the
pinned libwebrtc runtime, camera/microphone integration, media-message
encoders/playback, and sandbox/package behavior on the target distribution.

For now, users on these distributions should prefer the AppImage or Flatpak once those packages are verified on the target system. Native source-build instructions should only be added after complete testing of:

- login and encrypted database unlock
- OMEMO
- voice messages
- video messages
- 1:1 calls
- camera/microphone selection
- playback and previews

## Important Dependency Notes

### Media Runtime Boundaries

Live calls use the external `dinox-webrtc-worker` and
`libdinox-google-webrtc` runtime. Release builds must disable `plugin-rtp` and
must package the worker next to the wrapper. The same worker owns microphone,
camera and speaker devices for calls and media messages.

On Linux, the message recorder passes raw PCM/BGRA frames from libwebrtc to the
`ffmpeg` command. FFmpeg encodes AAC/H.264 and muxes M4A/MP4. On Windows,
Windows Media Foundation performs the encode/mux step instead.

GStreamer demuxes and decodes media files for playback, metadata and
thumbnails. Decoded audio reaches the selected libwebrtc speaker through an
`appsink` PCM bridge. GStreamer does not capture or mux Linux message
recordings and is not a live-call fallback.

Check representative non-call media elements:

```bash
gst-inspect-1.0 uridecodebin
gst-inspect-1.0 appsink
gst-inspect-1.0 qtdemux
gst-inspect-1.0 matroskademux
gst-inspect-1.0 avdec_aac
gst-inspect-1.0 avdec_h264
```

There are three direct DinoX-controlled FFmpeg uses on Linux:

1. The packaged/user-visible `ffmpeg` executable writes voice/video-message
   files.
2. The Google/libwebrtc runtime ships a minimal LGPL-only FFmpeg build as
   private `libavcodec-dinox-hw.so.62` and `libavutil-dinox-hw.so.60` siblings.
   It supplies VP8 VA-API receive acceleration and H.264 hardware providers:
   VA-API for supported Intel/AMD drivers, NVENC/NVDEC for supported NVIDIA
   drivers. Encoder and decoder independently fall back to WebRTC software.
   These libraries contain no muxer/demuxer and do not replace the message
   writer. Exact FFmpeg/libva/NVIDIA-header sources and notices are shipped.
3. The M152 WebRTC archive includes its pinned Chromium FFmpeg decoder and
   OpenH264 encoder as the portable H.264 software baseline. Its corresponding
   sources and notices are shipped alongside the runtime. The hardware adapter
   explicitly resolves its private siblings, with separate library filenames
   and ELF symbol versions to isolate the FFmpeg implementations.

Separately, the runtime or distribution GStreamer `libav` plugin can load its
own FFmpeg decoder libraries transitively for media playback. That additional,
runtime-supplied use is not linked or bundled directly by DinoX and is tracked
through the package/runtime inventory.

### SQLCipher and FTS5

DinoX uses SQLCipher for encrypted local databases. FTS5 is recommended for search behavior.

Check support:

```bash
sqlcipher :memory: "PRAGMA compile_options;" 2>/dev/null | grep -i FTS
```

The official package-builder image contains DinoX's pinned SQLCipher build with
FTS5. Workstation builds use the distribution library unless the developer
installs a separate upstream build explicitly.

### Pinned Google/libwebrtc Runtime

Release packages consume a prepared platform runtime rather than rebuilding
Chromium during every DinoX package job. Validate it before configuring:

```bash
./scripts/check-libwebrtc-linux-runtime.sh "$DINOX_LIBWEBRTC_RUNTIME_ROOT"
```

The Linux runtime manifest pins M152 branch 7977, commit
`6f37672d358475cd17544121a12494da454d85fb`, wrapper ABI 40, control IPC 10 and
video ring 6. Package jobs verify the archive SHA-256 and install the wrapper,
worker, offline Vision worker/models, codec metadata, corresponding sources
and license/patent notices. Older ABI 39/IPC 9 runtimes cannot be substituted
for these source/package inputs. Check the runtime manifest even when reusing
an existing dependency directory.
Calls retain VP8 and VP9. H.264 uses supported hardware automatically, with
independent software fallback for encoding and decoding. Hardware encoding
requires negotiated packetization mode 1 and usable bitrate control; a driver
that only offers constant-QP encoding stays on software. The existing VP8
VA-API receive path remains available. Hardware support must be checked on the
actual GPU and driver; a virtual display adapter alone provides no such proof.

The Windows runtime uses the same M152 pin. Its native wrapper, worker, codecs
and software fallback were validated on the Windows VM. A complete Windows
application build and interactive call acceptance remain separate release gates.

### CA Certificates

AppImage bundles the GnuTLS GIO module (`libgiognutls.so`), its ELF dependency
closure and `giomodule.cache`. `AppRun` sets `GIO_MODULE_DIR` to the private
module directory and clears `GIO_EXTRA_MODULES`, so incompatible host modules
cannot enter the bundled GLib process. This is separate from `libgnutls` and the CA bundle:
without a loadable GIO TLS backend, STARTTLS fails with `TLS support is not
available` before authentication. The static AppDir gate checks the module,
TLS registration in its cache, and the launcher path. Flatpak obtains this
backend from `org.gnome.Platform`; Windows ships its own GIO TLS module.

AppImage's `AppRun` probes common Linux CA bundle paths, including the openSUSE
and Fedora locations, and sets `GTLS_SYSTEM_CA_FILE`. Before creating network
sessions, DinoX loads that file through `g_tls_file_database_new()` and installs
it as the GIO backend's default database. The environment variable alone is not
consumed by the bundled GnuTLS backend. An invalid selected path stops startup
with an error; it never disables certificate or hostname verification. The
trust roots remain those maintained by the host system. Native Linux packages
keep their backend's normal trust handling. Flatpak uses the CA bundle from the
GNOME runtime. Windows uses the bundled certificate file when present and
otherwise the Windows TLS backend behavior.

Override the selected bundle when debugging an AppImage:

```bash
GTLS_SYSTEM_CA_FILE=/path/to/ca-bundle.pem ./DinoX-<version>-x86_64.AppImage
```

## Meson Options

Common options:

| Meson Option | Default | Description |
|---|---|---|
| `plugin-http-files` | enabled | HTTP file upload |
| `plugin-ice` | enabled | Legacy XEP-0176 ICE-UDP plus local-address/proxy helpers for Jingle S5B; Google/libwebrtc owns call ICE/STUN/TURN |
| `plugin-omemo` | enabled | OMEMO encryption |
| `plugin-openpgp` | enabled | OpenPGP support |
| `plugin-rtp` | enabled | Retired GStreamer call engine option; production builds explicitly disable it |
| `plugin-notification-sound` | auto | Notification sounds via libcanberra |
| `plugin-rtp-h264` | auto | Legacy `plugin-rtp` codec option; unused by production packages |
| `plugin-rtp-vaapi` | auto | Legacy `plugin-rtp` acceleration option; unused by production packages |
| `local-libomemo-c-root` | empty | Normal Linux build-tree prefix containing the pinned libomemo-c 0.5.1 and protobuf-c 1.5.2 runtime; release packages leave it empty |
| `google-libwebrtc-artifact-root` | empty | Development/proof input used to compile and stage the Linux runtime; not accepted by Linux package entry points |
| `google-libwebrtc-runtime-root` | empty | Prepared platform wrapper/worker runtime used by release packages |
| `google-vision-runtime-root` | empty | Separate offline inference runtime for development SDK builds; packaged builds use the Vision bundle included in `google-libwebrtc-runtime-root` |
| `google-libwebrtc-wrapper` | disabled | Native Google/libwebrtc wrapper adapter |
| `plugin-google-webrtc` | disabled | Production Google/libwebrtc call and media-message engine |
| `google-libwebrtc-tests` | false | Native/worker smoke executables for targeted verification; final production packages keep them disabled |
| `google-libwebrtc-test-oracle` | false | In-process development oracle; release artifacts use the external worker |
| `plugin-mqtt` | auto | MQTT integration |
| `location-sharing` | auto | GeoClue2 location sharing |

Fresh production builds must use the complete configuration shown in
“Configure, build and run”. The following commands only inspect or change an
already configured build:

```bash
meson setup build --reconfigure -Dplugin-mqtt=enabled
meson configure build | grep -E 'plugin|google-libwebrtc|location'
```

Google/libwebrtc release builds use the external worker unconditionally. The
in-process oracle exists only when compiled explicitly with
`-Dgoogle-libwebrtc-test-oracle=true` and must never be enabled in packages.
`DINOX_GOOGLE_WEBRTC_AUDIO_DEVICE=synthetic` remains a targeted test-harness
override; normal runs use libwebrtc's platform audio device module.

## Scripts Reference

### Source builders and contributors

| Script | Purpose |
|--------|---------|
| `scripts/prepare-linux-source-build-deps.sh` | Downloads and verifies the public Google/libwebrtc runtime and builds pinned protobuf-c 1.5.2 plus libomemo-c 0.5.1 into the ignored user-local source-build prefix. Run it before Meson. |
| `scripts/prepare-linux-tor-runtime.sh` | Optional, explicit local Tor/Lyrebird source build into `.vendor-deps/linux-tor-runtime`, with pinned Forgejo archives, verified reuse and staged replacement; also available through `scripts/build.sh --prepare-tor`. No system Tor, root installation or connection startup; `--self-test` is offline. |
| `scripts/check-libwebrtc-linux-runtime.sh` | Validates the downloaded x86_64 wrapper/worker runtime, ABI, private hardware codec libraries and source/license payload. Run it before Meson. |
| `scripts/build.sh` | Compiles the already configured `build/` tree, or an explicit `--build-dir DIR` (relative to the caller or absolute). `--strict` turns compiler warnings into a failed build; `--clean` cleans outputs but preserves the Meson configuration. |
| `scripts/run_all_tests.sh` | Runs static, Meson and DB suites. `--meson` performs the strict build plus all Meson-registered tests with the project timeout policy. |
| `scripts/package-runtime-matrix.sh` | Checks the local build, an existing `.deb`/AppDir, Flatpak manifest or metadata. Artifact modes require the corresponding artifact path. |
| `scripts/build-deb.sh` | Builds the amd64 `.deb` and checksum. Run it only through the verified package-builder command above. |
| `scripts/build-appimage.sh` | Builds the x86_64 AppImage, checksum, corresponding-source sidecar and sidecar checksum. Run it only through the verified package-builder command above. |
| `scripts/prepare-windows-build-deps.sh` | Prepares the public, pinned Windows Pango, Tor, libomemo-c, Lyrebird and Google/libwebrtc inputs plus verified custom-component license trees below the MSYS2 user's `$HOME`. |
| `scripts/build-windows-dist.sh` | Canonical clean Windows build and portable-distribution validation. Refuses elevated Administrator sessions before cleanup and automatically mirrors stdout/stderr to unique `compile-*.log` files in `$HOME/dinox-build-logs` (`DINOX_WINDOWS_LOG_DIR` selects another directory outside the checkout). Preserves build errors and fails on logging errors; `--self-test` checks logging, exit status and privilege refusal without running a Windows build. |
| `scripts/package-windows-dist.sh` | Revalidates an existing Windows `dist/`, requires the source commit and a checkout without tracked or untracked changes, removes same-name stale outputs before validation, creates the canonical normal-size `DinoX-VERSION-windows-x86_64.zip`, verifies exact archive-to-dist equality and writes the `.sha256` sidecar. A failed run leaves neither the ZIP nor its checksum behind. |

### Maintainer and CI-only helpers

These scripts are not additional workstation installation steps:

| Script | Purpose |
|--------|---------|
| `scripts/ci-build-deps.sh` | Root/container-only provisioning for the Linux package-builder image; not a public workstation bootstrap command. |
| `scripts/verify-ci-deps.sh` | Verifies the custom dependency install, including SQLCipher FTS5, libnice, libomemo-c, mosquitto, Tor and Lyrebird. |
| `scripts/verify-package-builder-image.sh` | Verifies that the Linux package-builder image manifest matches the current dependency scripts and Dockerfile. |
| `scripts/verify-package-builder-for-package-job.sh` | Verifies that the package-builder image is compatible with the current job. Invoke this non-executable file with `bash scripts/verify-package-builder-for-package-job.sh`. |
| `scripts/update-linux-package-builder-digest.sh` | Fail-closed updater for the three immutable Linux package-builder pins in the Forgejo package workflow; also validates the current structure, parses Docker push digests unambiguously and provides hermetic self-tests. |
| `scripts/mirror-appimage-runtimes.sh` | Downloads AppImage type2 runtimes, verifies generated `.sha256` files and can upload them to the Forgejo `vendor-deps` release; supports `--self-test` for offline argument and upload token validation. |
| `scripts/build-libwebrtc-artifact.sh` | Explicit external dependency-builder helper for the pinned M152 artifact, including H.264/VP9/VP8. Requires the published codec source archive through `--codec-sources`; supports `--dry-run` and `--self-test` and is not part of normal DinoX CI. |
| `scripts/build-libwebrtc-vp8-vaapi-dependency.sh` | Builds the pinned LGPL-only FFmpeg VA-API/NVENC/NVDEC provider as private dynamic libraries with libva 2.20 and NVIDIA codec-header baselines; stages exact sources and patches and supports `--dry-run`/`--self-test`. |
| `scripts/stage-libwebrtc-artifact.sh` | Stages a pinned Google/libwebrtc checkout into a compact DinoX artifact, including the required `--codec-sources` archive and codec notices. Validates it with `scripts/check-libwebrtc-artifact.sh` and can create a `.tar.gz` plus `.sha256`; supports `--self-test` without downloading WebRTC. |
| `scripts/build-libwebrtc-windows-runtime.sh` | Server-side native M152 Windows wrapper/worker build using the cached Windows toolchain, `--codec-sources` and the minimal MF/D3D11 provider from `--ffmpeg-root`. The published M152 ZIP is pinned separately in the Windows dependency helper; new candidates require Windows runtime validation. |
| `scripts/check-libwebrtc-artifact.sh` | Validates the prepared Google/libwebrtc artifact layout and manifest pin before proof builds use `-Dgoogle-libwebrtc-artifact-root=...`. |
| `scripts/configure-libwebrtc-wrapper-build.sh` | Configures a wrapper-enabled Meson proof build with a validated libwebrtc artifact and an explicit Clang >= 21 toolchain, normally Chromium clang from the WebRTC checkout; supports `--dry-run` and `--self-test`. |
| `scripts/check-windows-dist.sh` | Mandatory validation stage of `build-windows-dist.sh` and `package-windows-dist.sh`. It validates the Windows `dist/` file set, loads and registers all nine packaged plugins, requires all catalogs from the three LINGUAS files (currently 84 in total), performs German and Russian translation smokes, checks the complete hash-pinned Pango runtime, pinned Google/libwebrtc manifest, isolated GnuPG-agent/dirmngr lifecycle, GTK/GStreamer startup, executable helpers, transitive portable DLL closure and the hash-bound PE, runtime-asset, embedded-component and license-file inventories. It rejects unclassified files, build-machine paths, source archives or build caches anywhere in `dist/`, unused WMF support, legacy live-call artifacts and stale backup files; `--pango-runtime DIR` runs the same four-DLL gate before compilation. |
| `scripts/update_dist.sh` | Internal packaging stage used by `build-windows-dist.sh`; recreates `dist/` from scratch, resolves the final DLL closure, stages project/vendor/MSYS2 license texts and inventories, and removes an incomplete bundle if any package gate fails. For MSYS2 packages without installed license texts it verifies the exact signed source-only package and extracts only notice material into `dist/`. `--preflight-runtime-helpers` validates Tor/Lyrebird before compilation and `--self-test` covers helper errors without a Windows build. |
| `scripts/windows-license-inventory.py` | Stages and verifies the portable Windows license tree. Every actual PE file, including one with a nonstandard suffix, must have an exact source/package/hash match. Bundled themes, fonts, schemas, translations, Tor data and CA certificates are mapped to their source package; embedded Google/libwebrtc, Go runtime and every Lyrebird Go module are recorded separately. A second hash manifest covers every staged license file. The license tree is capped at 16 MiB and cannot contain source/package archives. |
| `scripts/forgejo-release.sh` | Creates/updates Forgejo releases and uploads release assets; validates tag format, local arguments, paired `.sha256` sidecars and uploaded checksum files before token/API work; supports `--self-test` for offline command dispatch, tag, body, asset and checksum validation checks. |
| `scripts/prepare-forgejo-release.sh` | Requires a local `vX.Y.Z` or `vX.Y.Z.W` tag, runs the static test gate, creates/updates the Forgejo release, writes release notes, archives that tag into the source tarball, verifies the source tarball `.sha256`, uploads both assets and supports `--self-test` for offline CLI and tag validation checks. |
| `scripts/verify-release-candidate.sh` | Verifies that a Forgejo Build workflow_dispatch release candidate succeeded on the exact commit SHA, with all Linux package jobs enabled, no release upload and successful Core/AppImage/Flatpak tasks; the full Meson suite remains part of the local release gate; supports `--self-test` without API access. |
| `scripts/release.sh` | Two-phase release helper. `--prepare` updates version, changelog, AppStream and DOAP metadata without changing the website, runs the local release gate, then commits and pushes only the release commit. `--finalize` verifies that exact commit is current on `origin`, then creates and pushes the tag; the tag starts one Linux release workflow. Supports `--self-test`. |
| `scripts/release_helper.sh` | Lightweight helper for changelog/development-plan/AppStream metadata updates; requires a clean working tree, runs the static test gate, then validates runtime matrix metadata plus the Flatpak manifest after release edits; supports `--self-test` for offline CLI and version argument validation. |
| `scripts/pre-commit` | Local Git hook for documentation links, translation syntax, hidden Unicode, Python/shell syntax self-test/check, local and Forgejo release helper self-tests, release-candidate verifier self-test, AppImage runtime mirror self-test, runtime matrix self-test, package metadata gates and compiler-warning checks. |
| `scripts/check-shell-syntax.sh` | Checks Git-tracked shell scripts under `scripts/` by `.sh` suffix or `sh`/`bash` shebang; supports `--self-test` for default discovery and accepts explicit script paths for targeted checks. |
| `scripts/check-python-syntax.py` | Checks Git-tracked Python files with `py_compile`; supports `--self-test` for built-in valid/broken Python samples. |
| `scripts/check_translations.py` | Checks PO syntax with `msgfmt`; supports `--syntax-only` for gating and `--self-test` for built-in valid/broken PO samples. |
| `scripts/check-doc-links.py` | Checks local Markdown links, embedded HTML links, website HTML links, DinoX Forgejo file and issue-template links, image-wrapper links, Markdown and HTML anchors, reference links and duplicate reference definitions in README, SECURITY, the website stub, internal docs and Forgejo templates; supports `--self-test`. |
| `scripts/scan_unicode.py` | Checks Git-tracked source and PO/POT translation files for hidden or dangerous Unicode characters; supports `--all-files` for a full tree scan and `--self-test` for built-in clean/suspicious samples. |
| `scripts/find_dead_code.py` | Heuristic Vala dead-code scanner; invoke it as `python3 scripts/find_dead_code.py`, optionally with `--root`. |

## Forgejo Actions

The package workflow is:

```text
.github/workflows/build.yml
```

It runs for release tags and for explicit `workflow_dispatch`; a normal push to
`master` does not build release packages. Manual runs expose these selections:

- `build_deb`
- `build_appimage`
- `build_flatpak`
- `release_candidate`
- `mirror_appimage_runtimes`
- `release_tag`
- `release_candidate_run`

The three package selectors are independent for ordinary manual verification.
For example, an AppImage-only or Flatpak-only run may skip the Core/Deb job.
Because `build_deb` defaults to `true`, explicitly disable it for an
AppImage-only or Flatpak-only run.
For a runtime mirror-only run, set `mirror_appimage_runtimes=true` and disable
all package build inputs.

Package jobs within each workflow run execute in sequence, with a Docker quota
of four CPUs and four compiler jobs (`DINOX_CI_JOBS=4`, `MAKEFLAGS=-j4` and
`CMAKE_BUILD_PARALLEL_LEVEL=4`). The workflow sets no container memory cap;
the runner and Docker-in-Docker daemon can already access the current host's
20 GB of shared RAM. Individual application services can have their own limits.
These settings are limits, not CPU or RAM reservations. Local build defaults
and builder-image defaults remain unchanged; the workflow overrides the Linux
package builder image's defaults of two jobs. A build-time improvement has not
yet been measured, and
higher parallelism does not remove hypervisor CPU steal.
Verification containers started through the Docker daemon have separate cgroups;
the workflow job's CPU quota does not also cap those containers.

An optional release-candidate run can still be used when package changes need a
separate dry run. Set `release_candidate=true`, `build_deb=true`,
`build_appimage=true`, `build_flatpak=true`, leave `release_tag` empty and keep
`release_candidate_run` empty and `mirror_appimage_runtimes=false`. This builds
the Linux packages and artifacts without publishing release assets. Run the
local release gate, including all Meson test suites, before dispatching it. The
Forgejo jobs then compile DinoX and run the package runtime and clean-install
gates without repeating the full Meson suite for every package build.

For the complete release order and required local dependency variables, follow
the [Windows release procedure](WINDOWS_BUILD_EN.md#10-publish-a-new-version-as-a-project-maintainer).
In particular, complete and review a clean Windows build and package from the frozen release
commit before pushing its tag. Keep the full Windows log outside the checkout;
do not repeatedly poll the VM. When the Windows gates and the local release
gates pass, tag that exact commit to start the single Forgejo Linux build.
The already checked Windows ZIP/checksum belong to that same commit and are
handed to the maintainer for the separate upload; no second Windows build is
needed merely because the tag was attached afterwards.

Normal releases do not require that optional dry run. Tag pushes matching
`v*.*.*` or `v*.*.*.*` run static preflight checks, then build Debian,
AppImage and Flatpak once and publish the checked assets through the Forgejo API.
Do not also start a manual `release_tag` workflow for the same tag; that would
queue a second complete package build.

If the normal tag workflow fails, use Forgejo's rerun action on that original
run (preferably only for failed jobs). This preserves the tag context and the
existing draft without requiring an RC or queuing a separate release workflow.

Manual `release_tag` runs are reserved for the separate case where a successful
optional RC already exists. Set
all three package selectors to `true`, set `release_tag` to the existing release
tag and set `release_candidate_run` to the numeric Forgejo Actions run ID of the
successful `release_candidate=true` Build run for that exact tagged commit. The
workflow-dispatch Git ref must select that same tag (or its exact commit);
dispatching another branch is rejected before package upload. The
run ID is the number shown in the Forgejo Actions run URL/list; it is not a Git
commit or job number. Dispatch validation rejects an empty or non-numeric value,
and `scripts/verify-release-candidate.sh` then verifies the run's repository,
workflow, exact commit SHA, enabled Linux package jobs and
absence of release uploads before the draft or release assets are changed.

Package workflow artifacts include the binary package and its `.sha256` file for Debian packages, AppImages and Flatpak bundles. Tag builds also verify checksum files before uploading release assets.

### Linux Package Builder Image

Debian and AppImage jobs use the DinoX-owned Linux package-builder image:

```text
git.dinox.im/dinoxim/linux-package-builder-dinox:ubuntu-24.04
```

Build and push it with:

```text
.github/workflows/linux-package-builder-image.yml
```

Run this image workflow before Deb/AppImage release builds when any of these
change:

- `.github/workflows/linux-package-builder-image.yml`
- `ci/images/linux-package-builder-dinox/Dockerfile`
- `scripts/scan_unicode.py`
- `scripts/ci-build-deps.sh`
- `scripts/verify-ci-deps.sh`
- `scripts/verify-package-builder-image.sh`
- `scripts/verify-package-builder-for-package-job.sh`
- `scripts/update-linux-package-builder-digest.sh`

The image workflow runs automatically on `master` only when its own workflow,
Dockerfile or dependency-provisioning inputs change; it can also be dispatched
manually. The package jobs verify the image with
`scripts/verify-package-builder-for-package-job.sh` and then run
`scripts/verify-ci-deps.sh`. This catches stale or incomplete custom dependency
contents before package creation.

Every image run validates the live package-workflow pins and rejects an already
stale queued source revision before starting the expensive build. It then builds
and verifies a run-unique tag first. The canonical and commit-specific tags are
created by that same build but are not published yet, so OCI provenance and
attestation manifests stay identical across all three tags. After publishing,
the workflow pulls that image back by its immutable registry digest and verifies
it again. A successful canonical `master` run then uses
`scripts/update-linux-package-builder-digest.sh` to replace exactly the three
Linux builder pins in `.github/workflows/build.yml` and pushes that small pin
commit with Forgejo's repository-scoped Actions token. Only after the pin commit
succeeds are the moving `ubuntu-24.04` and commit-specific aliases updated.
Digest updates therefore cannot be forgotten silently, cannot modify the
Flatpak builder pin and cannot recurse into another workflow run. If the source
inputs or `master` change incompatibly while the image is building, the run
fails instead of pinning a stale image.

Registry publication requires the dedicated `DINOX_REGISTRY_TOKEN` repository
secret. It is never reused for Git; the automatic repository-scoped Actions
token is used only for the small pin commit.

The image workflow also pins the official Ubuntu APT archive snapshot to the
UTC hour of the source commit. Binary packages and their exact corresponding
sources therefore remain available from the same historical Ubuntu repository
even after a normal mirror rotates an older update out. This is the Ubuntu APT
snapshot service, not Snap packaging: it adds no `snapd` dependency to DinoX or
to any end-user distribution. The builder's `catthehacker/ubuntu:act-24.04`
base is itself pinned by digest. Inherited PPA, packagecloud and Microsoft APT
sources are removed before the first package operation; the image and package
job gates reject every APT source except the two snapshot-pinned official Ubuntu
stanzas.

AppImage corresponding-source staging uses a separate temporary APT state for
that exact snapshot. An index refresh succeeds only when all required indexes
were retrieved; a partial refresh is never cached as ready. Transient download
failures have up to three APT retries and 30-second HTTP/HTTPS connection and inactivity
timeouts. Each index refresh has a 10-minute total limit, and each exact source
download has a 30-minute limit; termination escalates to killing its process
group after five seconds. A failed index refresh reports the snapshot and APT
exit status; failed source downloads also stop packaging with the exact package
request. Pinned versions and source validation remain unchanged.
The staging regression fixtures run with
`bash scripts/stage-package-licenses.sh --self-test` without fetching real APT
indexes or changing the host's package-manager state.

### Flatpak Builder Image

Flatpak package builds use a DinoX-owned builder image:

```text
git.dinox.im/dinoxim/flatpak-builder-dinox:gnome-50
```

Build and push it with:

```text
.github/workflows/flatpak-builder-image.yml
```

The image workflow runs automatically on `master` when its workflow or
Dockerfile changes and can also be dispatched manually. Run it before Flatpak
release builds when the Flatpak runtime, SDK, codecs or base image changes. A
manifest-only change does not rebuild this image automatically. The package
workflow checks its preinstalled refs and does not install missing runtimes
during the package build. This avoids unexpected runtime updates in a release
job.

After a successful image push, record its registry digest and update
`jobs.build-flatpak.container.image` in `.github/workflows/build.yml` to
`git.dinox.im/dinoxim/flatpak-builder-dinox@sha256:<new-digest>`. Commit that
pin before starting a package or release build. Unlike the Linux package-builder
workflow, this image workflow does not update the package-workflow pin itself;
publishing a new `gnome-50` tag alone leaves package jobs on the older image.

## Troubleshooting

### DEB installation troubleshooting

The official `.deb` is built for **Ubuntu 24.04 / Linux Mint 22.x on amd64**.
The file extension does not mean it works on every Debian-based distribution.
For **Debian 13 (Trixie) and derivatives**, use AppImage or Flatpak, or follow
the source-build instructions in this document.

[SparkyLinux 8.x is based on Debian 13](https://sparkylinux.org/sparky-8-4/),
so the same package choice applies. Use its 64-bit Intel/AMD edition for the
current DinoX binaries; Sparky also offers other architectures which these
downloads do not support. A runtime test on Sparky itself has not been performed.

On a supported Ubuntu/Mint system, open a terminal in the download directory,
verify the checksum, then install with APT (replace the filename with the one
you downloaded):

```bash
sha256sum -c dinox_2.3.3_amd64.deb.sha256
sudo apt update
sudo apt install ./dinox_2.3.3_amd64.deb
```

APT resolves runtime dependencies from the configured distribution repositories.
A file-manager installer or `dpkg -i` alone may stop at a missing dependency.
Do not fix a binary installation by installing development (`-dev`) packages.
`libgpgme11t64` is the runtime library for OpenPGP; `libgpgme-dev` is for
compiling software and is not the required replacement.

A report of `libgpgme11t64` being unavailable does not by itself identify the
distribution or prove that DinoX forgot to declare the dependency: it is
declared in the package and exists in both
[Ubuntu 24.04](https://packages.ubuntu.com/noble/libgpgme11t64) and
[Debian Trixie](https://packages.debian.org/trixie/amd64/libgpgme11t64).
Nevertheless, the Ubuntu-built DinoX binary also needs `libicu74`, while
[Trixie supplies ICU 76](https://packages.debian.org/trixie/libicu76).
Installing just GPGME therefore does not establish compatibility.

To report a failed installation, include the exact error and these read-only
diagnostics. They identify the actual derivative, architecture and configured
package candidates:

```bash
cat /etc/os-release
dpkg --print-architecture
apt-cache policy libgpgme11t64 libicu74
```

Do not mix Ubuntu repositories into Debian, remove dependency checks, or create
library symlinks to force installation. The AppImage and Flatpak downloads
avoid this particular distribution-library mismatch.

### Missing Dependency

Check the Meson error first. It usually names the missing pkg-config dependency.
On a workstation, install the corresponding distribution `-dev` package or an
upstream build in a dedicated prefix. Use `scripts/ci-build-deps.sh` only while
building the official root-owned package-builder container.

### GStreamer Element Missing

Use `gst-inspect-1.0 <element>`. If a non-call media element fails on
Debian/Ubuntu, check that `gstreamer1.0-plugins-bad`,
`gstreamer1.0-plugins-good`, `gstreamer1.0-plugins-ugly`,
and `gstreamer1.0-libav` are installed. Do not diagnose a production call or
Linux recording failure by searching for GStreamer RTP/encoder elements: those
paths use Google/libwebrtc plus the platform writer.

### Flatpak Codec Cache Looks Wrong

GStreamer keeps a registry cache. During local testing, stale cache entries can make fixed codecs still look unavailable. For the DinoX Flatpak sandbox, the cache is under:

```text
~/.var/app/im.dinox.dinox/cache/gstreamer-1.0/
```

Delete the registry file only when debugging a local broken test state.

### AppImage Works Differently Than Local Build

That usually means a required runtime library or GStreamer plugin is missing from the AppDir, or the host system provides a different device/media service. Inspect the extracted AppImage:

```bash
./DinoX-*.AppImage --appimage-extract
./scripts/package-runtime-matrix.sh appdir squashfs-root
find squashfs-root -maxdepth 5 -name 'libgst*.so' | sort
find squashfs-root -maxdepth 5 -name 'libnice*.so*' -print
```
