# Google/libwebrtc Dependency Proof

> Scope: Slice 2 dependency proof only
> Historical milestone: this proof predates the production cutover on `master`

The M150 commands and codec decisions below are preserved as historical proof.
They are not the current build recipe. Use [BUILD.md](BUILD.md) for supported
source builds and [runtime packaging](GOOGLE_WEBRTC_RELEASE_PACKAGING.md) for
the M152 Linux and Windows runtimes.

## 1. Decision

The first DinoX proof target is Google/libwebrtc M150, pinned to:

- Chromium milestone: `150`
- WebRTC branch: `refs/branch-heads/7871`
- WebRTC commit: `1f975dfd761af6e5d76d28333191973b258d82a8`
- First DinoX platform target: Linux x86_64 local build

This was selected on 2026-07-07 because ChromiumDash reports milestone 150 as
stable with `webrtc_branch` `7871`, and a direct `git ls-remote
https://webrtc.googlesource.com/src refs/branch-heads/7871` check resolves that
branch head to commit `1f975dfd761af6e5d76d28333191973b258d82a8`.

The proof deliberately pins a release branch head, not WebRTC `main`, because
DinoX needs reproducible release builds and a stable wrapper ABI boundary.

## 2. Upstream facts used for this slice

- Official WebRTC native development docs use depot_tools, `fetch --nohooks
  webrtc`, `gclient sync`, GN and Ninja for desktop builds:
  <https://webrtc.github.io/webrtc-org/native-code/development/>
- ChromiumDash milestone data maps Chrome/Chromium milestones to component
  branches, including `webrtc_branch`:
  <https://chromiumdash.appspot.com/fetch_milestones?only_branched=true>
- ChromiumDash release data exposes per-release component hashes, including the
  WebRTC hash used by Chrome stable builds:
  <https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Linux&num=5>
- WebRTC license and Additional IP Rights Grant must be carried into DinoX
  packaging artifacts:
  <https://webrtc.org/support/license>

## 3. Expected prepared artifact layout

The DinoX tree must not vendor a raw multi-gigabyte WebRTC checkout. The local
dependency builder should prepare a compact artifact root with this layout:

```text
libwebrtc-m150-linux-x86_64/
├── manifest.json
├── LICENSE
├── PATENTS
├── include/
│   ├── api/
│   │   ├── create_peerconnection_factory.h
│   │   └── peer_connection_interface.h
│   ├── logging/
│   └── ...
├── toolchain/
│   ├── libcxx-config/
│   ├── libcxx/include/
│   └── libcxxabi/include/
└── lib/
    ├── libwebrtc.a
    ├── libwebrtc-dinox-video.a
    ├── libc++.a
    └── libc++abi.a
```

`manifest.json` must contain at least:

```json
{
  "webrtc_milestone": 150,
  "webrtc_branch": "7871",
  "webrtc_commit": "1f975dfd761af6e5d76d28333191973b258d82a8",
  "target_os": "linux",
  "target_cpu": "x64",
  "artifact_abi": "dinox-libwebrtc-proof-v1"
}
```

`libwebrtc-dinox-video.a` contains the extra builtin video factory objects that
the upstream `webrtc` GN target does not include in `libwebrtc.a`. The libc++
archives are flattened copies of Chromium's generated static runtime archives;
raw Thin Archives are not transportable outside the WebRTC build tree.

This layout is enough for Meson to prove that DinoX can consume a pinned
artifact and link the native wrapper without changing call behavior.

## 4. Meson integration gate

The default build stays unchanged.

To validate a prepared artifact during Meson setup without compiling the native
wrapper:

```bash
meson setup build-libwebrtc-proof \
  -Dgoogle-libwebrtc-artifact-root=/absolute/path/to/libwebrtc-m150-linux-x86_64
```

With the option unset or empty, DinoX behaves exactly as before. With the option
set, Meson runs `scripts/check-libwebrtc-artifact.sh` and checks for:

- `manifest.json`
- `LICENSE`
- `PATENTS`
- `include/api/create_peerconnection_factory.h`
- `include/api/peer_connection_interface.h`
- `include/logging/rtc_event_log/events/rtc_event_ice_candidate_pair.h`
- `lib/libwebrtc.a`
- `lib/libwebrtc-dinox-video.a`
- `lib/libc++.a`
- `lib/libc++abi.a`
- Chromium libc++ headers/config under `toolchain/`
- manifest pin `webrtc_branch=7871`
- manifest pin `webrtc_commit=1f975dfd761af6e5d76d28333191973b258d82a8`

Wrapper-enabled Meson builds additionally require Clang >= 21 because the
pinned Chromium libc++ headers use newer compiler builtins. The reproducible
local proof path is to use Chromium's bundled compiler from the same WebRTC
checkout that produced the artifact:

```bash
scripts/configure-libwebrtc-wrapper-build.sh \
  --artifact-root /absolute/path/to/libwebrtc-m150-linux-x86_64 \
  --webrtc-src /absolute/path/to/webrtc/src \
  --build-dir build-google-webrtc \
  --wipe
```

The helper validates the artifact with a header compile probe, sets `CC` and
`CXX` to Chromium clang/clang++, prepends the toolchain directory to `PATH`,
forces `lld` through `CC_LD=lld`, `CXX_LD=lld` and `-fuse-ld=lld`, and
configures Meson with
`-Dgoogle-libwebrtc-wrapper=enabled`.

After configure, the minimal native wrapper proof is:

```bash
ninja -C build-google-webrtc google-webrtc/google-webrtc-wrapper-smoke
meson test -C build-google-webrtc google-webrtc-wrapper-smoke --print-errorlogs
```

This dependency is intentionally not wired into the call plugin yet. Runtime
integration starts in the later wrapper/Jingle slices.

## 5. Artifact validation helper

Use the helper before passing the artifact to Meson:

```bash
scripts/check-libwebrtc-artifact.sh /absolute/path/to/libwebrtc-m150-linux-x86_64
```

Optional header syntax probe:

```bash
DINOX_LIBWEBRTC_COMPILE_PROBE=1 \
  CXX=/path/to/webrtc/src/third_party/llvm-build/Release+Asserts/bin/clang++ \
  scripts/check-libwebrtc-artifact.sh /absolute/path/to/libwebrtc-m150-linux-x86_64
```

The helper enforces the current pin:

- `DINOX_LIBWEBRTC_BRANCH=7871`
- `DINOX_LIBWEBRTC_COMMIT=1f975dfd761af6e5d76d28333191973b258d82a8`

These environment variables are overridable only for intentional future pin
updates.

## 6. Artifact staging helper

After the external WebRTC checkout has been built, stage the compact DinoX
artifact and optionally package it:

```bash
scripts/stage-libwebrtc-artifact.sh \
  --webrtc-src /path/to/webrtc/src \
  --build-out /path/to/webrtc/src/out/dinox-linux-x64 \
  --artifact-root /tmp/libwebrtc-m150-linux-x86_64 \
  --package
```

The staging helper validates the checkout commit, copies public headers,
`LICENSE`, `PATENTS`, `libwebrtc.a`, the DinoX video-factory supplement,
flattened Chromium libc++ static archives and the required libc++ headers,
writes `manifest.json`, runs `scripts/check-libwebrtc-artifact.sh`, then
creates a `.tar.gz` and `.sha256` when `--package` is used.

The self-contained release packaging strategy is documented in
`docs/internal/GOOGLE_WEBRTC_RELEASE_PACKAGING.md`.

## 7. External build helper

Use the explicit external builder when the artifact should be produced from
scratch:

```bash
scripts/build-libwebrtc-artifact.sh \
  --work-dir ~/src/dinox-libwebrtc-m150 \
  --artifact-root /tmp/libwebrtc-m150-linux-x86_64 \
  --jobs "$(nproc)" \
  --force
```

The helper uses depot_tools, fetches the pinned WebRTC branch, verifies the exact
commit, runs GN/Ninja in the external work directory and then calls
`scripts/stage-libwebrtc-artifact.sh`.

Use `--dry-run` first to inspect the commands without downloading or building
WebRTC:

```bash
scripts/build-libwebrtc-artifact.sh \
  --work-dir ~/src/dinox-libwebrtc-m150 \
  --artifact-root /tmp/libwebrtc-m150-linux-x86_64 \
  --dry-run
```

## 8. Build notes for the dependency builder

The dependency builder is not part of normal DinoX builds. It should run in a
separate checkout/work directory because WebRTC pulls a large Chromium toolchain
and dependency tree.

Initial Linux x86_64 build outline:

```bash
mkdir -p ~/src/dinox-libwebrtc-m150
cd ~/src/dinox-libwebrtc-m150

# depot_tools must be in PATH.
fetch --nohooks webrtc
cd src
git fetch origin refs/branch-heads/7871:refs/remotes/origin/branch-heads/7871
git checkout -B dinox-m150-webrtc origin/branch-heads/7871
gclient sync

gn gen out/dinox-linux-x64 --args='
  target_os="linux"
  target_cpu="x64"
  is_debug=false
  is_component_build=false
  rtc_include_tests=false
  rtc_build_examples=false
  treat_warnings_as_errors=false
  use_rtti=true
  use_custom_libcxx=true
'

ninja -C out/dinox-linux-x64 \
  webrtc \
  obj/api/video_codecs/libbuiltin_video_encoder_factory.a \
  obj/api/video_codecs/libbuiltin_video_decoder_factory.a
```

After the raw build succeeds, the dependency builder must stage the compact
artifact root described above and run `scripts/check-libwebrtc-artifact.sh`.

## 9. Non-goals for this slice

- no call UI changes
- no `VideoCallPlugin` replacement
- no Jingle/SDP converter implementation
- no GStreamer RTP removal
- no Windows/AppImage/Flatpak packaging yet

## 10. Acceptance state

Current Slice 2 repository state:

- selected libwebrtc revision is documented
- artifact layout is documented
- Meson has a disabled-by-default artifact proof option
- validation helper exists
- staging and package helper exists
- explicit external build helper exists
- wrapper-enabled configure helper exists
- self-contained release packaging strategy is documented
- the first Linux x86_64 artifact was produced and validated on the dependency
  builder
- the native wrapper was compiled and linked against the staged artifact on the
  dependency builder
- DinoX Meson configured the wrapper with Chromium clang 23 and `ld.lld`, built
  `google-webrtc/google-webrtc-wrapper-smoke`, and passed the ABI v7 smoke test
  against the staged artifact, including local offer, remote offer, local answer,
  remote answer application, local audio source/track state checks, answer-side
  audio sender binding, remote audio sink attachment, synthetic PCM capture
  through libwebrtc and a local two-session ICE-connected proof
- current RTP call runtime remains unchanged

Still open outside this commit:

- decide whether release package jobs compile the wrapper with a suitable
  toolchain or consume a prebuilt DinoX wrapper artifact
- wire the wrapper into the Jingle/SDP bridge behind an explicit development
  call-engine boundary

Slice 3 wrapper ABI work is tracked separately in
`docs/internal/GOOGLE_WEBRTC_WRAPPER_ABI.md`.
