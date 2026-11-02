# Google/libwebrtc Worker and Native ABI

> Native ABI: 40
> Control IPC: 10
> Video ring: 6
> Linux and Windows runtime: M152, branch 7977, commit `6f37672d358475cd17544121a12494da454d85fb`

The current runtime adds local video effects and the offline Vision worker to
the existing M152 source pin. Native Windows codec, worker and tray probes have
passed; the complete 2.3.2 application build-log review and user call tests are
separate acceptance gates. See [runtime packaging](GOOGLE_WEBRTC_RELEASE_PACKAGING.md)
for the exact immutable archives, source commits and remaining performance checks.

## Purpose

DinoX must not expose libwebrtc C++ types or API churn to Vala, GTK or XMPP
code. The public header `google-webrtc/include/dinox_webrtc.h` is therefore the
stable C boundary. In production its functions are process proxies: native
libwebrtc objects exist only in `dinox-webrtc-worker`, never in the DinoX GTK
process.

The old direct transport is available only when the build explicitly enables
`-Dgoogle-libwebrtc-test-oracle=true`. Release profiles keep that option off.
The obsolete `DINOX_WEBRTC_INTERNAL_WORKER` environment variable cannot bypass
process isolation; only the worker executable can enter internal-worker mode
through the process-local bootstrap function.

## Runtime layout

```text
DinoX / google-webrtc plugin
  -> libdinox-google-webrtc.so or dinox-google-webrtc.dll
     -> framed local control IPC
        -> dinox-webrtc-worker
           -> pinned Google/libwebrtc platform runtime
```

- Linux uses a local socket pair and an inherited shared-memory file descriptor.
- Windows uses a named pipe, a named file mapping and a Job Object.
- Audio capture, processing, RTP and playout remain entirely in the worker.
- Local preview and remote video frames use the bounded shared-memory ring.
- XMPP, JMI/Jingle, OMEMO trust decisions and GTK remain in DinoX.

The wrapper DLL/shared library contains proxy handles only. `DinoXWebrtcContext`,
`DinoXWebrtcSession`, `DinoXWebrtcVideoPipeline` and
`DinoXWebrtcMediaRecorder` are opaque to callers and do not expose libwebrtc
ownership.

## ABI surface

The ABI covers these operation groups:

- build metadata and status strings
- context creation and shutdown
- microphone, speaker and camera enumeration/selection
- device volume and speaker/microphone/camera tests
- session creation, offer/answer, remote descriptions and ICE candidates
- audio/video track controls, DTMF and local DTMF feedback
- bounded PCM message playback, including pause, flush, finish and stop
- camera capture and local/remote video frame callbacks
- outgoing-video effect capabilities, logical pipeline lifecycle, typed
  configuration revisions and bounded aggregate diagnostics
- session diagnostics and the low-bandwidth policy
- audio/video message recorder creation, capture and teardown

All current structs carry or are checked against ABI 40. The runtime checker also
requires the exact platform pin, artifact ABI, control protocol and video-ring
version from `manifest.json`.

M152 offers VP8, VP9 and a portable H.264 baseline (OpenH264 encoder, Chromium
FFmpeg decoder). Internal encoder/decoder factories retain those SDP formats
and wrap hardware providers with libwebrtc's independent software fallbacks:

- Linux uses private FFmpeg for VA-API H.264 encode/decode and NVIDIA
  NVENC/NVDEC, plus the existing VP8 VA-API receive path.
- Windows uses private FFmpeg's hardware Media Foundation encoder and D3D11VA
  decoder. MF creation, processing and destruction stay on one codec thread.
- H.264 hardware encoders require packetization mode 1 and the negotiated
  profile/level. Mode 0 retains software encoding. Unsupported hardware or
  missing bitrate control selects software without changing the agreed codec.

Private `-dinox-hw` libraries are loaded explicitly from beside the wrapper,
separately from Chromium's static FFmpeg and the application's file-media
libraries. Hardware-only pixel formats, encoded SPS/profile checks and runtime
failure handling prevent an internal software path from being reported as GPU
processing. CUDA device discovery alone does not establish NVDEC capability;
its power-efficiency query stays conservative without a real decode proof.

Linux hardware bitrate changes use bounded encoder restarts because FFmpeg's
VA-API and NVENC APIs do not reliably report every dynamic rate update.
Small changes use hysteresis; a substantial reduction that would require a
second restart within one second switches to the software rate controller.
Each hardware restart produces SPS/PPS and an IDR. Windows applies bitrate
updates through the private MF dependency patch and falls back on failure.

These are provider contracts. Actual hardware execution requires a successful
device/driver frame test; an unavailable-device skip or software fallback pass
does not establish Intel, AMD, NVIDIA or Windows GPU coverage.

## Native MUJI description preparation

Introduced with ABI 39/control IPC 9 and retained in ABI 40/control IPC 10,
MUJI has an explicit prepare/commit boundary:

1. `dinox_webrtc_session_prepare_local_description` creates an offer or answer
   without setting it on the native peer connection. The appended
   `on_local_description_prepared` callback delivers that generated SDP.
2. The MUJI adapter applies the frozen conference payload IDs, MIDs and packet
   times while retaining the original source and transport attributes.
3. `dinox_webrtc_session_set_local_description` commits the projected SDP.
   Its `on_local_description` callback reads the actual committed native
   description. The owner verifies that result before publishing Jingle and
   releasing its bounded local ICE backlog.

This prevents signaling-only identity changes that can leave connected peers
unable to decode each other's media. The automatic `create_offer` and
`create_answer` APIs retain their existing direct-call behavior. Both new
operations and the prepared event use the same worker isolation and generation
checks as the existing description path; video ring 6 is unchanged.

## IPC contract

`google-webrtc/include/dinox_webrtc_ipc.h` defines a fixed 48-byte
little-endian header containing:

- magic and protocol version
- message type and flags
- request ID
- session/recorder ID
- generation
- bounded payload length

Control payloads are limited to 1 MiB. Decoders reject unknown message types,
invalid flags and enum values, truncated or oversized payloads, invalid
recorder metadata and stale generations before allocating or dispatching.
Handshake metadata is compiled from the pinned build constants, so the
standalone IPC target does not depend on a wrapper symbol merely to validate
the artifact identity.

The supervisor applies bounded startup, request and shutdown timeouts. A worker
abort or hang fails active operations once, reaps the process, and permits a
fresh worker only for a later operation. It never silently changes to the
in-process engine and never restarts an active call in a loop.

Normal logs do not contain SDP, ICE passwords, TURN credentials or per-frame /
per-10-ms audio output. Detailed diagnostics require
`DINOX_GOOGLE_WEBRTC_CALL_DEBUG=1`; lifecycle timing additionally requires
`DINOX_GOOGLE_WEBRTC_LIFECYCLE_DEBUG=1`.

## Outgoing-video effect control plane

ABI 35 and control IPC 4 introduced the no-op control plane required by the
staged video-call-effects work. ABI 36 and control IPC 5 added the first
visible, opt-in `GRAYSCALE` processor and route the same processed frame to the
outgoing track and local preview. Control IPC 6 keeps ABI 36 and fences the
video-ring-v5 mailbox layout and wake-up semantics from older workers. ABI 37
and control IPC 7 add `WARM_TONE` as a second closed-contract enum value and
capability bit. ABI 38 and control IPC 8 add native local-source frame
diagnostics and make one logical video pipeline a proven capture/effect fan-out
owner for all peer sessions in a MUJI call. Video-ring 6 expands the bounded
mailbox to five slots so four remote streams and one local preview cannot starve
one another.

ABI 40 and control IPC 10 extend that same shared pipeline with typed colour
adjustments, background assets, person framing, single-face accessories and scene
decorations. The current contract is:

- The complete default configuration is passthrough: `NONE`, neutral picture
  adjustments, no background, framing or overlays. Call start and capability
  discovery do not activate an effect or load an inference model.
- Capabilities carry separate masks for presets, backgrounds, framing and
  decorations. A declared enum does not by itself make that choice available.
- One physical capture and one processed frame feed the currently attached
  MUJI peers, with one local-preview publisher. Attach/detach/destroy preserve
  pipeline and subscriber generations and reject stale identities.
- Configuration acceptance and application use distinct revisions. The worker
  replies to `SET_CONFIG` before publishing its revision-bound state event.
- The preset list includes Grayscale, Warm/Cold tone, Sepia, Light leak, Dreamy,
  Prism light, Fisheye, Vintage TV, Frosted glass, Duo tone and Underwater.
  Brightness, contrast, saturation and sharpening are separate adjustments.
- Background modes are Off, Blur, Solid colour and Image. Upload/builtin,
  prepare and release use bounded, opaque asset IDs rather than file paths.
  Vala validates still PNG/JPEG input before supplying decoded pixels.
  Selecting an image first activates a solid background while the chooser/load
  is pending. Cancelling or failing that selection retains that solid background
  rather than promising restoration of the previous image.
- The separate offline `dinox-vision-worker` provides person segmentation and
  single-face detection for the selections that need them. Colour-only effects
  use the native processor. All model files and licenses ship in the runtime.
- Processing uses bounded latest-frame storage and guarded publication. A
  watchdog reports degradation rather than growing an unbounded frame queue.
  Background concealment is checked before publication, including model/worker
  failure and stale-frame paths; basic colour and concealment effects have
  different failure policies.
- The call UI applies selections asynchronously through the backend interface.
  A new call starts with effects off. Live interop, device quality and frame-time
  acceptance remain release checks, particularly the Fisheye/sharpening budget
  recorded in [runtime packaging](GOOGLE_WEBRTC_RELEASE_PACKAGING.md).

The reply-before-event guarantee belongs to the production control wire. The
explicitly enabled in-process test oracle proves state/revision behavior but
is not a release runtime or proof of C-function-return scheduling.

## Video ring

`google-webrtc/src/dinox_webrtc_video_ring.*` defines video-ring version 6:

- five fixed-size slots for four remote streams plus one local preview
- ordered recorder delivery and latest-frame-wins Local/Remote mailboxes
- one bounded control-channel wake-up per unread live stream
- generation, dimensions, stride, pixel format, frame-ID and sequence checks
- atomic per-slot ownership tied to the exact notification token
- dropped frames when every slot is busy instead of an unbounded queue

The tokenized slot state prevents a reader and writer from concurrently copying
the same pixel storage and prevents a Local, Remote or Recorder notification
from claiming a foreign or reused slot. A live replacement preserves the one
outstanding notification token. If the proxy consumes that token while the
replacement is being written, the state handshake rearms exactly one follow-up
notification instead of losing the newest frame or building a stale-event
queue. GTK only receives an owned BGRA view/copy and creates textures on its
main context. Frames from a previous session generation are rejected.

## Vala ownership

`EngineContext` is the single plugin context. Calls, recorders and device tests
acquire activity leases. `close()` marks the context for shutdown and releases
the native proxy only after the final lease is returned.

Context creation and plugin shutdown are protected by a mutex. Device catalog
refresh may run in a background thread, but shutdown cannot invalidate its
native context while the short enumeration lease is active. A generation check
prevents a stale catalog from replacing a newer Preferences result.

Session, video-pipeline and recorder callbacks have teardown barriers. Late
native events are discarded after close/cancel, and GTK signal delivery is
marshalled to the captured GLib main context. Rapid pipeline state changes are
coalesced to one pending latest state instead of creating an unbounded GLib
source queue.

`EngineMujiGroupSession` owns one logical native video pipeline for the whole
room call. Exact full-JID peer sessions are attached and detached under that
owner; camera selection, capture start/stop, effect state and publisher handover
are group operations rather than per-peer capture lifecycles. A stale peer,
publication token or callback cannot publish into a replacement attachment.

## Low-bandwidth mode

The network policy is typed, not a raw SDP rewrite:

- `Automatic` preserves normal libwebrtc behavior.
- `Low bandwidth (2G)` creates an audio-only session.
- The worker applies a 16 kbit/s maximum to the negotiated Opus sender and
  enables supported adaptive packet-duration behavior.
- Jingle advertises compatible mono, DTX, in-band FEC and receiver constraints.
- Diagnostics report policy, configured cap, measured bitrate and RTP counters
  separately. `opus/48000` remains the correct negotiated clock rate.

Failure to apply the policy is a hard session error; DinoX does not label an
automatic session as 2G mode.

## Build modes

Build the large M152 dependency checkout on the server. The artifact builder
and stager require `--codec-sources` pointing to the published, hash-checked
M152 codec source archive. When reusing already built output through
`build-libwebrtc-artifact.sh`, pass `--skip-fetch`, `--skip-sync` and
`--skip-build` to skip fetching, synchronization and compilation. The wrapper
build below consumes the resulting compact artifact; it does not fetch
Chromium sources.

Source-wrapper development build on Linux:

```bash
scripts/configure-libwebrtc-wrapper-build.sh \
  --artifact-root /absolute/path/to/libwebrtc-m152-linux-x86_64 \
  --webrtc-src /absolute/path/to/webrtc/src \
  --build-dir build-google-webrtc \
  --wipe
```

Release/package builds consume a prepared runtime through:

```bash
-Dplugin-rtp=disabled \
-Dplugin-google-webrtc=enabled \
-Dgoogle-libwebrtc-wrapper=enabled \
-Dgoogle-libwebrtc-runtime-root=/absolute/path/to/platform-runtime
```

The runtime contains the wrapper, worker, license and patent notices, manifest,
and platform-native smoke executables. End users do not install libwebrtc.

## Required validation

The source build runs:

- IPC protocol fixtures and malformed-input checks
- video-ring concurrency and metadata checks
- executor ordering oracle
- worker handshake/lifecycle smoke
- process crash, hang, restart and old-env-bypass smoke
- video-pipeline wire ordering, generations, bounded state delivery,
  callback-owned teardown and implicit session-close cleanup
- engine/context/recorder lifecycle smoke, including concurrent device refresh
  versus context close
- signaling, Jingle, JMI and audio-only process smokes
- actual software encode/decode cycles for VP8, VP9 profile 0 and the
  advertised H.264 encoder profiles and packetization modes
- bidirectional worker-backed Opus/video calls forced to H.264, VP9 or VP8,
  plus the existing MUJI SDP projection smoke
- private Linux VP8/VA-API provider binding without a GPU, followed by the
  optional hardware-backed decoder smoke on a compatible device
- separate H.264 hardware encoder and decoder frame tests, with unavailable
  capabilities reported as skips rather than hardware passes
- hardware initialization/runtime failure injection into the real M152
  fallback wrappers, including independent directions, IDR recovery and RTP
  timestamp wraparound
- bounded Linux hardware rate updates and unavailable-device software fallback

Windows additionally checks private MF/D3D11 provider presence without a GPU
and runs the same native IPC, video-ring and process smokes, plus the Media
Foundation M4A/AAC and MP4/H.264/AAC writer smoke. The packaged
application gate is complete only when the Windows VM build contains the worker
runtime and passes those native checks without an installed external libwebrtc.
