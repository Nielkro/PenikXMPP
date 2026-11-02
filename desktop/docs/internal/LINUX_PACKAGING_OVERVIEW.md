# Linux Packaging Overview

This document is the short, authoritative overview of DinoX Linux packaging.
Exact commands, dependencies and release gates are maintained in
[BUILD.md](BUILD.md). Do not copy old package commands into this file.

## Supported outputs

| Output | Build baseline | User-facing target |
|---|---|---|
| Debian-format package | Ubuntu 24.04 package-builder image | Ubuntu 24.04 and Linux Mint 22.x |
| AppImage | Ubuntu 24.04 package-builder image | Portable Linux x86_64 package |
| Flatpak bundle | GNOME Platform/Sdk 50 and Freedesktop 25.08 extensions | Sandboxed Linux package |
| Native source build | Ubuntu 24.04, Linux Mint 22.x or Debian 13 | Developer or distribution-local build |

The Ubuntu 24.04 `.deb` is not a Debian 13 binary package. Debian 13 users
should use the AppImage or Flatpak, or build DinoX natively against Debian 13.

## Google/libwebrtc runtime

Production calls and audio/video-message capture use the pinned
Google/libwebrtc M152 worker runtime. Normal source and package builds do not
compile Chromium/WebRTC. They download the public Linux runtime archive from
the Forgejo [`vendor-deps`](https://git.dinox.im/dinoxim/dinox/releases/tag/vendor-deps)
release and verify the SHA-256 pinned in the repository.

The current source and all three package consumers require wrapper ABI 40,
control IPC 10 and video ring 6. The archive includes the offline Vision worker,
person/face models, their exact hashes and original license texts. They stay
beside the WebRTC worker; no model download is performed during calls.

M152 retains Opus audio and VP8/VP9 video compatibility. H.264 has a portable
OpenH264/Chromium-FFmpeg software baseline and optional private FFmpeg hardware
providers: VA-API for Intel/AMD and NVENC/NVDEC for compatible NVIDIA drivers.
Encoder and decoder fall back independently to software when capabilities,
initialization or processing fail. The existing VP8 VA-API receive path remains
available. H.264 hardware encoding requires negotiated packetization mode 1
and usable bitrate control; mode 0 uses the software encoder. A GPU that offers
only constant-QP encoding does not satisfy the call encoder's rate-control
requirements. Actual GPU execution remains a separate device/driver test.

Local source builds use `debugoptimized` so video comparisons with packaged
release builds include compiler optimization.

Deb and AppImage builds intentionally accept only
`DINOX_LIBWEBRTC_RUNTIME_ROOT`. They reject `DINOX_LIBWEBRTC_ARTIFACT_ROOT`:
the much larger build artifact is consumed explicitly through
`configure-libwebrtc-wrapper-build.sh --artifact-root` to compile the wrapper
and stage the compact runtime, not as a release-package environment input.

The current download, verification and extraction commands are in
[BUILD.md](BUILD.md#prepare-the-pinned-linux-source-build-dependencies). Runtime
structure, ABI, licenses and corresponding sources are documented in
[GOOGLE_WEBRTC_RELEASE_PACKAGING.md](GOOGLE_WEBRTC_RELEASE_PACKAGING.md).

## Media and network boundaries

- Google/libwebrtc owns live-call media, microphone/camera capture, speaker
  output and call ICE/STUN/TURN.
- On Linux, an `ffmpeg` executable encodes and muxes audio/video messages as
  AAC/M4A or H.264+AAC/MP4.
- GStreamer demuxes and decodes media files, produces metadata and thumbnails,
  and feeds decoded audio PCM to the selected libwebrtc speaker. It is not the
  production call engine or the Linux recorder muxer.
- The Linux libwebrtc runtime also contains private, LGPL-only FFmpeg libraries
  for VP8 receive decoding and H.264 VA-API/NVENC/NVDEC hardware providers.
  Their `-dinox-hw` library names distinguish them from system media libraries.
  They are separate from the
  `ffmpeg` executable used for message files and from WebRTC's internal H.264
  decoder. Notices and exact corresponding sources accompany both codec builds.
- `libnice` remains for the separately packaged legacy XEP-0176 ICE plugin. That
  plugin also provides local-address discovery and per-account Tor/SOCKS5
  policy hooks for direct Jingle-S5B file transfer. `libnice` does not provide
  ICE/STUN/TURN for production Google/libwebrtc calls.

## Official package builds

Deb and AppImage builds run in the DinoX-owned Ubuntu 24.04 package-builder
image referenced by `.github/workflows/build.yml`. The image provisions pinned
package-only dependencies under `/opt/dinox-deps`. Developers must not run
`scripts/ci-build-deps.sh` as a normal workstation bootstrap command.

The package entry points are:

```text
scripts/build-deb.sh
scripts/build-appimage.sh
im.dinox.dinox.json
```

Use the complete container and Flatpak commands from
[BUILD.md](BUILD.md#ubuntu-2404--linux-mint-22-debian-format-package),
[BUILD.md](BUILD.md#appimage) and [BUILD.md](BUILD.md#flatpak). The workflow
performs package-specific runtime, dependency-closure and clean-install gates;
a successful compile alone is not a releasable package.

The AppImage keeps the normal Linux desktop ABI outside the package:
glibc/toolchain, X11, Wayland, fonts, audio and graphics. Its static AppDir gate
allows exactly that boundary and requires every other ELF dependency in the
AppDir. The following cold gate is therefore not a bare server installation:
`ci/images/appimage-runtime-gate/Dockerfile` pins Debian 13 by digest and adds
only the explicit desktop ABI payloads, without installing their transitive
package dependencies. The preceding static All-ELF closure therefore remains
the authoritative protection against mandatory AppDir libraries being masked
by anything already present in the minimal base. The final AppImage then runs
with no container network as an unprivileged user and must report the exact
version; its bundled GnuPG agent and dirmngr must also complete a
launch/shutdown lifecycle.

The official Ubuntu package-builder is tied to an immutable APT archive
snapshot. The AppImage source stager first uses its local exact-source cache and
normal Ubuntu source repository, then uses that same official snapshot if a
normal mirror has already rotated the required version out. This has no
relationship to Snap packages and creates no `snapd` runtime dependency. The
builder base image is pinned by digest, and its inherited third-party APT
sources are removed before use; package gates allow only the two official
Ubuntu stanzas pinned to that snapshot.

The AppImage additionally publishes a mandatory matching `.sources.tar.xz`
release sidecar. The runnable AppImage remains slim: it contains the project and
third-party notices, file-to-package inventory, license metadata and a
hash-pinned source-offer manifest, but not the large corresponding-source
archives themselves. The sidecar contains the identical non-payload compliance
tree plus the exact Ubuntu source packages, recorder FFmpeg/x264 sources and
Google/libwebrtc compliance payload. The build and release gates compare the
sidecar with the final AppImage and reject missing, additional or changed
payloads.

Normal Forgejo Actions runs keep these outputs separate as well:
`dinox-appimage` contains only the runnable AppImage and checksum, while
`dinox-appimage-corresponding-sources` contains only the source sidecar and its
checksum. DEB and Flatpak artifacts likewise contain only their installable
package and checksum. The source sidecar remains available without becoming a
mandatory package download.

The package workflow fails before upload when an installable DEB exceeds
160 MiB, an AppImage exceeds 256 MiB or a Flatpak bundle exceeds 512 MiB.
Corresponding-source archives are excluded from those package limits because
they are separate compliance artifacts.

For the other custom-built dependencies, the sidecar contains every staged
license plus `METADATA` with the exact public source URL and checksum rather
than a duplicate source archive. Those public source assets must remain
available with the release. The matching DinoX source itself is the Forgejo
release tag/source archive, not a second copy in this sidecar.
The Flatpak uses GNOME 50 plus its matching Freedesktop 25.08 codec/runtime
extensions and downloads the same pinned Google/libwebrtc Linux runtime as the
other Linux production packages.

The private IBus client correction is included in Deb, AppImage and Flatpak.
It is selected only for the identified affected system client; it does not
replace the system daemon or install an additional package repository.
Linux tray menus use GIO session D-Bus and the in-tree SNI/DBusMenu exporter
with PNG colour icons. Flatpak retains the StatusNotifierWatcher permission;
the desktop host supplies the native menu theme.

## Version 2.3.2 preparation

The next release is prepared locally as 2.3.2, with development/unreleased
metadata. This preparation does not build or publish package artifacts.
Before finalizing the version/date and pushing its tag, review the current
Windows build log, complete the user runtime checks and obtain the explicit
release go described in [RELEASE_READINESS.md](RELEASE_READINESS.md).

## Flatpak and Flathub

`im.dinox.dinox.json` is the Forgejo build manifest and uses the local checkout
as its DinoX source. It is suitable for DinoX CI and release bundles, but not as
a final Flathub submission manifest. A Flathub submission must replace the
local source with an immutable public release tag and full commit SHA and must
be reviewed and submitted by a human maintainer.

The current requirements and remaining submission work are tracked in
[FLATHUB_SUBMISSION_PLAN.md](FLATHUB_SUBMISSION_PLAN.md). Flathub is an
additional distribution channel; the directly published Forgejo Flatpak,
AppImage and Deb remain independent release outputs.

## Installation and source builds

End-user installation commands and checksums are documented in
[README.md](../../README.md#installation). Native source-build dependencies,
the public libwebrtc runtime download, Meson options and validation commands are
documented in [BUILD.md](BUILD.md). Package maintainers should also follow the
release-candidate and Forgejo Actions procedure in that document.
