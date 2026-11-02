# Google/libwebrtc Release Packaging

> Runtime artifact ABI: `dinox-libwebrtc-runtime-v2`

## Release model

Official DinoX packages ship the complete platform runtime required by the
Google/libwebrtc call engine. End users do not install depot_tools,
`libwebrtc-dev`, a GStreamer call plugin or a separate audio-processing library.

Normal package CI does not rebuild Chromium/WebRTC. A dependency builder creates
one pinned runtime archive per platform, and package jobs verify its SHA-256
before extracting it. The archives include the DinoX wrapper and worker, not a
multi-gigabyte WebRTC checkout or the private Windows build toolchain.

Current Linux pin:

- milestone: 152
- branch: `refs/branch-heads/7977`
- commit: `6f37672d358475cd17544121a12494da454d85fb`
- wrapper ABI: 40
- control IPC: 10
- video ring: 6
- video: VP8 preferred, with VP9 and H.264 negotiated from peer capabilities
- H.264: VA-API/NVENC encoding and VA-API/NVDEC decoding where supported,
  with independent built-in OpenH264/FFmpeg software fallbacks
- Linux VP8 receive: VA-API after real key/delta decoding, image-output and
  latency checks against libvpx; otherwise software decoding
- VP8 encode: libwebrtc/libvpx on the CPU

The Linux runtime was built from clean DinoX commit
`41db6217bde34446dc44773ce2c17b02a654d22f`. The explicit MUJI prepare/commit
boundary is preserved: conference payload IDs, MIDs and packetization times
are applied before local SDP is signaled. Hardware encoding requires usable
bitrate control and negotiated H.264 packetization mode 1. Unsupported devices
and initialization or processing failures use the software codec. Hardware
availability is independently checked for encoding and decoding.

The Windows runtime uses the same M152 source pin and ABI/IPC/ring versions.
It is built from clean DinoX commit `d38c8ab34c04b2dc142adf550cfa5b70284561a5`.
The server build, runtime checks and native Windows VM probes completed. The
current full application build-log review and interactive call tests remain
pending for 2.3.2. Older assets remain available so older source tags keep their
reproducible inputs. Do not reuse an older local ABI 39/IPC 9 directory for the
current ABI 40/IPC 10 release gate.

The WebRTC M152 SDK and codec source pin have not changed. This generation adds
DinoX's own video-effect code and a separate, offline inference worker built
from pinned TensorFlow Lite/XNNPACK sources. It also bundles the two small
person-segmentation and face-detection models. Normal application builds
download this complete runtime; they do not rebuild the WebRTC SDK or fetch
models during calls. Models are used only when the selected effect needs them.

This runtime generation is for effect testing and prerelease integration.
Physical-device acceptance remains open, and Fisheye with sharpening has not
yet met the required 8 ms frame-processing budget. Building or checksum-testing
an archive does not establish live-call or performance acceptance.

## Linux runtime

The source wrapper is built once against the prepared Linux WebRTC artifact and
then staged with:

```bash
scripts/stage-libwebrtc-linux-runtime.sh \
  --build-dir build-google-webrtc-local \
  --runtime-root /absolute/path/libwebrtc-m152-linux-x86_64-runtime \
  --vision-runtime /absolute/path/linux-vision-package/runtime-staging \
  --force
```

Output:

```text
libwebrtc-m152-linux-x86_64-runtime/
  include/dinox_webrtc.h
  lib/libdinox-google-webrtc.so
  lib/dinox-webrtc-worker
  lib/dinox-vision-worker
  lib/dinox-vision-models/selfie_segmenter_landscape-v1.tflite
  lib/dinox-vision-models/blaze_face_short_range-v1.tflite
  lib/dinox-vision-licenses/
  lib/dinox-vision-runtime-manifest.json
  lib/dinox-vision-SHA256SUMS
  lib/libavcodec-dinox-hw.so.62
  lib/libavutil-dinox-hw.so.60
  sources/ffmpeg-8.1.2.tar.xz
  sources/libva-2.20.0.tar.gz
  sources/nv-codec-headers-n8.1.24.15.tar.gz
  sources/ffmpeg-dinox-symbol-versions.patch
  manifest.json
  LICENSE
  LICENSE.md
  PATENTS
  FFMPEG-LICENSE
  LIBVA-LICENSE
  FFMPEG-VP8-VAAPI.json
  NVIDIA-CODEC-HEADERS-LICENSE
  WEBRTC-CODECS.json
  WEBRTC-GN-ARGS.gn
  sources/webrtc-m152-codec-sources-6f37672d3584-sha256-2b17c14cc13b.tar.gz
libwebrtc-m152-linux-x86_64-runtime-abi40-ipc10-sha256-2479cdb9ab7e.tar.gz
libwebrtc-m152-linux-x86_64-runtime-abi40-ipc10-sha256-2479cdb9ab7e.tar.gz.sha256
```

The repository-side trust anchor is the full SHA-256
`2479cdb9ab7eace826e28d519a9dd33478329e34c303ed716c196005d9cec46f`.

`scripts/check-libwebrtc-linux-runtime.sh` verifies the manifest pin, ELF/PIE
layout, the binary WebRTC pin, `$ORIGIN` worker lookup, required C exports, the private FFmpeg library
closure and the libva runtime boundary. The wrapper resolves the packaged
`libavcodec-dinox-hw.so.62` and `libavutil-dinox-hw.so.60` beside itself instead of a system
FFmpeg installation. The archive is made deterministically with fixed
ownership, order and timestamp.

The same gate also requires the Vision worker, exact model hashes, source
provenance and original dependency licenses. `scripts/check-vision-runtime.py`
checks that bundle independently. Do not copy only the WebRTC library: the
Vision worker and model directories must remain beside it.

The current archive manifest binds the wrapper and worker to the clean DinoX
source commit `41db6217bde34446dc44773ce2c17b02a654d22f`. Runtime builders reject
dirty source trees, and consumers reject manifests without this source
provenance before packaging.

The Linux runtime ships a minimal LGPL-only FFmpeg 8.1.2 build as private
dynamic sibling libraries. It provides VP8 VA-API decoding plus H.264
VA-API/NVENC encoding and VA-API/NVDEC decoding. It is compiled against libva
2.20 and pinned NVIDIA codec headers; the actual driver comes from the host.
No CUDA toolkit is required. Hardware usability depends on the codec profile,
resolution, driver and usable bitrate control. Encoders offering only
constant-QP operation are rejected. Rate changes are bounded to avoid repeated
encoder recreation; a rapid second substantial bitrate drop switches that
encoder to software. Missing or failed GPU support does not disable calls.

These private libraries are unrelated to the Linux `ffmpeg` executable used
to write chat media messages. They contain no muxer/demuxer. The archive carries
the exact FFmpeg, libva and NVIDIA-header sources, patch and license material.
Separate SONAMEs and private ELF symbol versions isolate these libraries from
both GStreamer playback dependencies and Chromium's static codec copy.

M152 also links Chromium's separate FFmpeg decoder and OpenH264 encoder as the
portable software baseline. Hardware adapters resolve FFmpeg functions through
their private library handles. `WEBRTC-CODECS.json` records the built-in codec
recipe and exact corresponding codec-source archive; `WEBRTC-GN-ARGS.gn`
records the build arguments. All source archives and notices are installed.
Build and stage the dependency with:

```bash
scripts/build-libwebrtc-vp8-vaapi-dependency.sh \
  --work-dir /path/to/dependency-work \
  --output-root /path/to/ffmpeg-vp8-vaapi \
  --jobs 8

scripts/build-libwebrtc-artifact.sh \
  --work-dir /path/to/dinox-libwebrtc-m152 \
  --artifact-root /path/to/libwebrtc-m152-linux-x86_64 \
  --vp8-vaapi-root /path/to/ffmpeg-vp8-vaapi \
  --codec-sources /path/to/webrtc-m152-codec-sources-6f37672d3584-sha256-2b17c14cc13b.tar.gz \
  --skip-fetch --skip-sync --skip-build --force
```

Release builds consume the immutable Forgejo `vendor-deps` asset named
`libwebrtc-m152-linux-x86_64-runtime-abi40-ipc10-sha256-2479cdb9ab7e.tar.gz`.
Forgejo Actions and the Flatpak manifest must contain its full SHA-256. Every
new runtime generation gets a new ABI/IPC/content-addressed name; never replace
an asset referenced by an older source tag. Upload the new archive before
committing its URL and checksum, otherwise every package job fails.

`google-libwebrtc-artifact-root` and the configure helper's `--artifact-root`
are restricted to development/proof builds that compile the wrapper before
`stage-libwebrtc-linux-runtime.sh` creates the compact runtime. The former
package environment fallback `DINOX_LIBWEBRTC_ARTIFACT_ROOT` is rejected. Deb
and AppImage builds require the validated compact runtime through
`DINOX_LIBWEBRTC_RUNTIME_ROOT`; this prevents packages from bypassing the
runtime-v2 manifest, sibling-library and `$ORIGIN` validation gate.

With a scoped token in the environment, the fixed infrastructure tag accepts
the archive and its verified sidecar:

```bash
FORGEJO_TOKEN=... scripts/forgejo-release.sh upload vendor-deps \
  /path/libwebrtc-m152-linux-x86_64-runtime-abi40-ipc10-sha256-2479cdb9ab7e.tar.gz \
  /path/libwebrtc-m152-linux-x86_64-runtime-abi40-ipc10-sha256-2479cdb9ab7e.tar.gz.sha256
```

## Windows runtime

The Windows runtime is cross-built on the Linux dependency server from the
pinned M152 checkout using the existing Chromium MSVC/Windows SDK toolchain cache.
Build a new candidate before promoting its immutable URL and SHA-256:

```bash
scripts/build-libwebrtc-windows-runtime.sh \
  --webrtc-src /path/to/webrtc/src \
  --toolchain-cache /path/to/toolchain-cache \
  --runtime-root /path/to/libwebrtc-m152-windows-x86_64-runtime \
  --build-out /path/to/webrtc/src/out/m152-win-x64 \
  --ffmpeg-root /path/to/ffmpeg-windows-hardware \
  --codec-sources /path/to/webrtc-m152-codec-sources-6f37672d3584-sha256-2b17c14cc13b.tar.gz \
  --vision-runtime /path/to/windows-vision-package/runtime-staging \
  --jobs 2 --force --skip-sync
```

The M152 hardware dependency is built separately with
`scripts/build-libwebrtc-windows-codec-dependency.sh`. It supplies the uniquely
named `avcodec-dinox-hw-62.dll` and `avutil-dinox-hw-60.dll`: hardware-only Media
Foundation encoding and D3D11VA decoding, with WebRTC software fallback for each
direction. The runtime artifact contains original FFmpeg sources and the exact
Media Foundation patch. The portable application includes notices, metadata,
patch text and `CODEC-SOURCES.md` with public source URLs and SHA-256 values;
large source archives remain outside its license tree.

Published output:

```text
libwebrtc-m152-windows-x86_64-runtime/
  bin/dinox-google-webrtc.dll
  bin/dinox-webrtc-worker.exe
  bin/dinox-vision-worker.exe
  bin/dinox-vision-models/selfie_segmenter_landscape-v1.tflite
  bin/dinox-vision-models/blaze_face_short_range-v1.tflite
  bin/dinox-vision-licenses/
  bin/dinox-vision-runtime-manifest.json
  bin/dinox-vision-SHA256SUMS
  bin/dinox-webrtc-ipc-protocol-smoke.exe
  bin/dinox-webrtc-video-ring-smoke.exe
  bin/dinox-webrtc-process-engine-smoke.exe
  bin/dinox-webrtc-muji-sdp-smoke.exe
  bin/dinox-webrtc-windows-codec-provider-smoke.exe
  bin/dinox-webrtc-video-codec-smoke.exe
  bin/avcodec-dinox-hw-62.dll
  bin/avutil-dinox-hw-60.dll
  lib/libdinox-google-webrtc.dll.a
  include/dinox_webrtc.h
  manifest.json
  LICENSE
  LICENSE.md
  PATENTS
libwebrtc-m152-windows-x86_64-runtime-abi40-ipc10-sha256-32ebb90ba8cb.zip
libwebrtc-m152-windows-x86_64-runtime-abi40-ipc10-sha256-32ebb90ba8cb.zip.sha256
```

The public ZIP is pinned in the Windows dependency helper to SHA-256
`32ebb90ba8cbe340dc7e398db8f38a8df5d74204a58b78618888afe0e465db44`.
Its content-addressed name is immutable. Keep older runtime assets for older
source tags; the repository-side full hash, not the sidecar alone, is the trust
anchor. Its manifest binds the DLL and worker to the same clean DinoX source
commit `d38c8ab34c04b2dc142adf550cfa5b70284561a5`.

For integration testing, publish the statically checked archive and its
verified sidecar to the fixed public dependency release. Record any pending
VM execution checks explicitly. A Windows application release still requires
the native VM gates below:

```bash
FORGEJO_TOKEN=... scripts/forgejo-release.sh upload vendor-deps \
  /path/libwebrtc-m152-windows-x86_64-runtime-abi40-ipc10-sha256-32ebb90ba8cb.zip \
  /path/libwebrtc-m152-windows-x86_64-runtime-abi40-ipc10-sha256-32ebb90ba8cb.zip.sha256
```

The import library is generated from the actual DLL exports for MinGW/MSYS2
consumers. The runtime checker validates PE files, manifest versions and the
required import symbols. Native acceptance includes IPC, video ring, process
engine, MUJI SDP, provider loading, codec roundtrips, injected runtime failure
and H.264/VP9/VP8 worker loops. The VM without GPU video facilities additionally
runs `--expect-no-hardware` and `--unavailable-device`; these two checks are
VM-specific. These Windows execution checks have not yet been run for this
ABI40 archive. Physical MF/D3D11, VA-API and AMD/NVIDIA device acceptance also
remain separate requirements; prior runtime results do not certify this new
generation.

The Chromium toolchain ZIP is build input only and must never be placed in a
DinoX source, runtime or release archive.

## Inference sources and licenses

The matching desktop inference source recipe is published separately as
`dinox-vision-desktop-sources-46b1d2639244-f36320e8.tar.gz` under the same
`vendor-deps` release, with SHA-256
`939119005e1a6f6fb62367ec8d0e097daba4161dd702788529003e1573cdcee6`.
It contains the exact DinoX inference sources, producer, model bytes, original
model/custom-op license and pinned build recipe used by both desktop runtimes.
It is a source companion, not an additional application download or a copy of
the Chromium SDK/toolchain. Its cached upstream dependencies are identified
by revision and original license hashes.

Runtime builders first produce the separate Vision bundle using
[`scripts/vision-runtime/README.md`](../../scripts/vision-runtime/README.md),
then supply its `runtime-staging` directory through `--vision-runtime`. The
inference target reuses the existing pinned checkout/toolchains and builds
only its own isolated targets; it does not rebuild the full WebRTC SDK.

The installed `dinox-vision-licenses` tree preserves original license texts for
every reachable third-party source root, plus model/custom-op and DinoX
licenses. The manifest binds those texts, models and worker to their exact
hashes and source recipe. Linux keeps this tree in `/usr/lib/dinox` (Flatpak:
`/app/lib/dinox`); Windows keeps it beside the DLL in the portable directory
and includes it in the distribution license inventory.

## Package integration

Linux application package recipes select `--buildtype=debugoptimized` (O2 with
debug information). The independent native WebRTC libraries use a release GN
configuration (`is_debug=false`).

All production profiles use:

```text
-Dplugin-rtp=disabled
-Dplugin-google-webrtc=enabled
-Dgoogle-libwebrtc-wrapper=enabled
-Dgoogle-libwebrtc-runtime-root=<validated runtime root>
-Dgoogle-libwebrtc-test-oracle=false
-Dgoogle-libwebrtc-tests=false
```

Smoke executables are enabled only in a separate strict test configuration;
package builds compile the production plugin and immutable runtime gates. The
local release runner and Windows distribution builder compile the smoke graph
with strict warnings, run its platform tests, and restore the production graph
even when that test phase fails.

- AppImage and Deb copy the Linux wrapper, both workers, models and notices into the DinoX
  private runtime directory.
- Flatpak downloads the same pinned Linux archive and verifies its SHA-256.
- Windows `update_dist.sh` copies the DLL, both workers, models and licenses beside DinoX and rejects a
  packaged legacy RTP/GStreamer call plugin.
- On Linux, Google/libwebrtc captures raw message PCM/BGRA and the packaged
  `ffmpeg` command encodes/muxes M4A/MP4. On Windows, Media Foundation performs
  that writer step without a system `ffmpeg` executable.
- GStreamer remains for media-file demux/decode, playback, metadata and
  thumbnails; decoded audio PCM is routed to the libwebrtc speaker. It is not a
  recorder muxer or live-call fallback.
- Google/libwebrtc owns call ICE/STUN/TURN. `libnice` remains only because the
  separately packaged legacy ICE plugin also supplies local-address discovery
  and Tor/SOCKS5 policy hooks to direct Jingle-S5B file transfer.

## Release gates

- runtime checker passes for the target platform
- runtime archive checksum verifies locally and in package CI
- wrapper, both workers, exact models and Vision license/manifest files are present in the produced package
- Linux packages provide the FFmpeg executable/encoders needed by the
  media-message writer; Windows packages pass the Media Foundation writer smoke
- WebRTC LICENSE/PATENTS, generated WebRTC dependency licenses, FFmpeg LGPL,
  libva MIT and dependency manifests are installed
- old RTP plugin and GStreamer RTP/WebRTC/DTLS/SRTP/NICE call plugins are absent
- in-process test oracle is absent from release builds
- native worker crash/hang recovery smokes pass
- Linux and Windows application builds pass their media/UI test matrix
- Automatic and low-bandwidth audio plus video interop pass the agreed live
  acceptance matrix

`scripts/package-windows-dist.sh` validates the portable Windows bundle and
creates the ZIP with a SHA-256 sidecar. It does not perform Authenticode signing;
a successful package check must not be described as a signed Windows release.
